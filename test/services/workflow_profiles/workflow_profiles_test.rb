require "test_helper"
require_relative "../../support/workflow_profile_test_helper"

class WorkflowProfiles::WorkflowProfilesTest < ActiveSupport::TestCase
  include WorkflowProfileTestHelper

  test "creates an owner-scoped immutable revision with ordered snapshots and deterministic digest" do
    profile = create_workflow_profile
    revision = profile.current_revision

    assert_equal users(:normal), profile.user
    assert profile.active?
    assert_equal 1, revision.version
    assert_equal 2, revision.role_count("translator")
    assert_equal 1, revision.role_count("reviewer")
    assert_equal 1, revision.role_count("judge")
    assert_equal 0, revision.role_count("finalizer")
    assert_equal (1..2).to_a, revision.selections_for("translator").map(&:position)
    assert revision.model_selections.all?(&:routing_identity_available?)
    assert_equal 64, revision.configuration_digest.length
    assert_equal revision.configuration_digest, WorkflowProfiles::ConfigurationDigest.call(revision)
    assert_not revision.update(name: "Mutated history")
    assert_not revision.model_selections.first.update(display_name_snapshot: "Mutated history")
  end

  test "editing appends revision two and stale competing edits do not overwrite" do
    profile = create_workflow_profile
    original = profile.current_revision
    revised = WorkflowProfiles::Revise.call(
      workflow_profile: profile,
      expected_version: 1,
      attributes: workflow_profile_attributes(name: "Second revision")
    )

    assert_equal 2, revised.version
    assert_equal revised, profile.reload.current_revision
    assert_equal "Faithful automatic workflow", original.reload.name
    assert_raises WorkflowProfiles::Revise::StaleRevisionError do
      WorkflowProfiles::Revise.call(
        workflow_profile: profile,
        expected_version: 1,
        attributes: workflow_profile_attributes(name: "Lost update")
      )
    end
    assert_equal 2, profile.revisions.count
  end

  test "digest ignores display name but changes with routing and ordered role facts" do
    profile = create_workflow_profile
    revision = profile.current_revision
    duplicate = revision.dup
    duplicate.model_selections = revision.model_selections.map(&:dup)
    duplicate.model_selections.first.display_name_snapshot = "Cosmetic rename"
    assert_equal revision.configuration_digest, WorkflowProfiles::ConfigurationDigest.call(duplicate)

    duplicate.model_selections.first.model_identifier_snapshot = "changed/routing-id"
    assert_not_equal revision.configuration_digest, WorkflowProfiles::ConfigurationDigest.call(duplicate)
  end

  test "enforces completion-specific role limits and active OpenRouter eligibility" do
    error = assert_raises WorkflowProfiles::BuildRevision::InvalidSelectionError do
      WorkflowProfiles::Create.call(
        user: users(:normal),
        attributes: workflow_profile_attributes.merge(translator_ids: [ llm_models(:openrouter_claude).id ])
      )
    end
    assert_match(/at least 2/, error.message)

    inactive = LlmModel.create!(
      gateway: "openrouter", provider: "test", model_identifier: "test/inactive-profile",
      display_name: "Inactive", active: false
    )
    assert_raises WorkflowProfiles::BuildRevision::InvalidSelectionError do
      WorkflowProfiles::Create.call(
        user: users(:normal),
        attributes: workflow_profile_attributes.merge(reviewer_ids: [ inactive.id ])
      )
    end

    assert_raises ActiveRecord::RecordInvalid do
      WorkflowProfiles::Create.call(
        user: users(:normal),
        attributes: workflow_profile_attributes.merge(finalizer_ids: [ llm_models(:openrouter_claude).id ])
      )
    end
  end

  test "deactivate reactivate and duplicate preserve safe history" do
    profile = create_workflow_profile
    WorkflowProfiles::ChangeStatus.deactivate(workflow_profile: profile)
    assert_not profile.reload.active?
    WorkflowProfiles::ChangeStatus.activate(workflow_profile: profile)
    assert profile.reload.active?

    duplicate = WorkflowProfiles::Duplicate.call(workflow_profile: profile)
    assert_equal users(:normal), duplicate.user
    assert_equal "Copy of #{profile.name}", duplicate.name
    assert_equal profile.configuration_digest, duplicate.configuration_digest
    assert_equal 1, duplicate.current_revision.version
  end
end
