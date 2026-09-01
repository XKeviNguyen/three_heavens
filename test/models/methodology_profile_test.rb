require "test_helper"
require_relative "../support/methodology_profile_test_helper"

class MethodologyProfileTest < ActiveSupport::TestCase
  include MethodologyProfileTestHelper

  test "creation trims outer values preserves guidance formatting and computes behavioral digest" do
    profile = MethodologyProfiles::Create.call(
      user: users(:normal),
      attributes: methodology_profile_attributes(
        name: "  Faithful method  ",
        source_language: "  Vietnamese ",
        target_language: " Japanese  ",
        guidance: "\n  Preserve outer trimming.\n  Keep this internal indentation.\n\nKeep this paragraph.  \n"
      ).merge(description: "  Description  ")
    )
    revision = profile.current_revision

    assert_equal "Faithful method", revision.name
    assert_equal "Description", revision.description
    assert_equal "Vietnamese", revision.source_language
    assert_equal "Japanese", revision.target_language
    assert_equal "Preserve outer trimming.\n  Keep this internal indentation.\n\nKeep this paragraph.", revision.guidance
    assert_equal MethodologyProfiles::ConfigurationDigest.call(revision), revision.configuration_digest

    cosmetic_copy = profile.revisions.build(
      version: 2,
      name: "Cosmetic rename",
      description: "Different description",
      source_language: revision.source_language,
      target_language: revision.target_language,
      guidance: revision.guidance
    )
    cosmetic_copy.valid?
    assert_equal revision.configuration_digest, cosmetic_copy.configuration_digest
  end

  test "revision is immutable in Rails and PostgreSQL" do
    revision = create_methodology_profile.current_revision

    assert_not revision.update(guidance: "Changed")
    assert_includes revision.errors[:base], "Methodology profile revisions are immutable"
    assert_not revision.destroy

    assert_raises ActiveRecord::StatementInvalid do
      MethodologyProfileRevision.transaction(requires_new: true) do
        revision.update_columns(guidance: "Callback bypass")
      end
    end
    assert_equal "Preserve theological nuance.\n\nUse a natural literary register.", revision.reload.guidance
  end

  test "database rejects a revision whose digest does not match its behavioral payload" do
    profile = create_methodology_profile

    assert_raises ActiveRecord::StatementInvalid do
      MethodologyProfileRevision.transaction(requires_new: true) do
        MethodologyProfileRevision.insert_all!([ {
          methodology_profile_id: profile.id,
          version: 2,
          name: "Forged digest",
          source_language: "Vietnamese",
          target_language: "Japanese",
          guidance: "Different behavior",
          configuration_digest: "0" * 64,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end
    assert_equal 1, profile.revisions.count
  end

  test "revision service creates a new immutable snapshot and rejects stale editors" do
    profile = create_methodology_profile
    first = profile.current_revision
    second = MethodologyProfiles::Revise.call(
      methodology_profile: profile,
      expected_version: "1",
      attributes: methodology_profile_attributes(guidance: "Second methodology")
    )

    assert_equal 2, second.version
    assert_equal first, profile.revisions.find_by!(version: 1)
    assert_equal "Second methodology", profile.reload.current_revision.guidance
    assert_raises MethodologyProfiles::Revise::StaleRevisionError do
      MethodologyProfiles::Revise.call(
        methodology_profile: profile,
        expected_version: "1",
        attributes: methodology_profile_attributes(guidance: "Stale edit")
      )
    end
    assert_equal 2, profile.revisions.count
  end

  test "profiles archive reactivate and cannot be destructively deleted" do
    profile = create_methodology_profile

    MethodologyProfiles::ChangeStatus.deactivate(methodology_profile: profile)
    assert_not profile.reload.active?
    MethodologyProfiles::ChangeStatus.activate(methodology_profile: profile)
    assert profile.reload.active?
    assert_not profile.destroy
  end

  test "experiment enforces owner language snapshot immutability and optional methodology" do
    project = users(:normal).projects.create!(
      name: "Methodology experiment",
      source_language: " vietnamese ",
      target_language: "JAPANESE"
    )
    document = project.documents.create!(title: "Source", source_text: "Source")
    methodology = create_methodology_profile
    experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      methodology_profile_revision: methodology.current_revision
    )

    assert_equal methodology.current_revision, experiment.methodology_profile_revision
    assert_not experiment.update(methodology_profile_revision: nil)
    assert_includes experiment.errors[:methodology_profile_revision], "cannot change after experiment creation"
    assert_raises ActiveRecord::StatementInvalid do
      Experiment.transaction(requires_new: true) do
        Experiment.where(id: experiment.id).update_all(methodology_profile_revision_id: nil)
      end
    end
    assert_equal methodology.current_revision, experiment.reload.methodology_profile_revision
    assert document.experiments.create!(instruction_prompt: "No methodology").valid?

    mismatch = create_methodology_profile(target_language: "English")
    invalid = document.experiments.build(
      instruction_prompt: "Translate.",
      methodology_profile_revision: mismatch.current_revision
    )
    assert_not invalid.valid?
    assert_includes invalid.errors[:methodology_profile_revision], "must match the project's source and target languages"
  end

  test "administrator status does not bypass methodology ownership" do
    methodology = create_methodology_profile(user: users(:normal))
    project = users(:admin).projects.create!(
      name: "Admin project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.build(
      instruction_prompt: "Translate.",
      methodology_profile_revision: methodology.current_revision
    )

    assert_not experiment.valid?
    assert_includes experiment.errors[:methodology_profile_revision], "is not available for this experiment"

    assert_raises ActiveRecord::StatementInvalid do
      Experiment.transaction(requires_new: true) do
        Experiment.insert_all!([ {
          document_id: experiment.document_id,
          instruction_prompt: "Callback bypass",
          status: "pending",
          methodology_profile_revision_id: methodology.current_revision_id,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end
  end

  test "database rejects parent mutations that would invalidate a methodology snapshot" do
    methodology = create_methodology_profile
    project = users(:normal).projects.create!(
      name: "Protected project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Protected document", source_text: "Source")
    experiment = document.experiments.create!(
      instruction_prompt: "Translate.",
      methodology_profile_revision: methodology.current_revision
    )
    other_project = users(:other).projects.create!(
      name: "Other project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    other_document = other_project.documents.create!(title: "Other document", source_text: "Source")

    assert_database_rejects { Project.where(id: project.id).update_all(target_language: "English") }
    assert_database_rejects { Project.where(id: project.id).update_all(user_id: users(:other).id) }
    assert_database_rejects { Document.where(id: document.id).update_all(project_id: other_project.id) }
    assert_database_rejects { MethodologyProfile.where(id: methodology.id).update_all(user_id: users(:other).id) }
    assert_database_rejects { Experiment.where(id: experiment.id).update_all(document_id: other_document.id) }

    assert_equal "Japanese", project.reload.target_language
    assert_equal users(:normal), project.user
    assert_equal project, document.reload.project
    assert_equal users(:normal), methodology.reload.user
    assert_equal document, experiment.reload.document
  end

  private

  def assert_database_rejects
    assert_raises ActiveRecord::StatementInvalid do
      ActiveRecord::Base.transaction(requires_new: true) { yield }
    end
  end
end
