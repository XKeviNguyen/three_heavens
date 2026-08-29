require "test_helper"
require_relative "../support/workflow_profile_test_helper"

class WorkflowProfilesAndPipelinesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
  end

  test "owner creates edits duplicates and changes lifecycle without mutating history" do
    assert_difference -> { WorkflowProfile.count }, 1 do
      post workflow_profiles_path, params: { workflow_profile: profile_params }
    end
    profile = WorkflowProfile.order(:id).last
    assert_redirected_to workflow_profile_path(profile)
    assert_equal 1, profile.current_revision.version

    assert_difference -> { WorkflowProfileRevision.count }, 1 do
      patch workflow_profile_path(profile), params: {
        workflow_profile: profile_params.merge(name: "Revision two", expected_version: "1")
      }
    end
    assert_redirected_to workflow_profile_path(profile)
    assert_equal 2, profile.reload.current_revision.version
    assert_equal "Browser profile", profile.revisions.find_by!(version: 1).name

    assert_difference -> { WorkflowProfile.count }, 1 do
      post duplicate_workflow_profile_path(profile)
    end
    assert_redirected_to workflow_profile_path(WorkflowProfile.order(:id).last)

    patch deactivate_workflow_profile_path(profile)
    assert_not profile.reload.active?
    patch activate_workflow_profile_path(profile)
    assert profile.reload.active?
  end

  test "stale profile edit returns conflict and preserves current revision" do
    profile = create_workflow_profile
    WorkflowProfiles::Revise.call(
      workflow_profile: profile,
      expected_version: 1,
      attributes: workflow_profile_attributes(name: "Already revised")
    )

    patch workflow_profile_path(profile), params: {
      workflow_profile: profile_params.merge(name: "Stale overwrite", expected_version: "1")
    }
    assert_response :conflict
    assert_select "li", text: /changed while you were editing/
    assert_equal "Already revised", profile.reload.name
  end

  test "profile resources are strictly owner scoped even for admin-like private access" do
    other_profile = create_workflow_profile(user: users(:other))
    get workflow_profile_path(other_profile)
    assert_response :not_found
    patch workflow_profile_path(other_profile), params: {
      workflow_profile: profile_params.merge(expected_version: "1")
    }
    assert_response :not_found
  end

  test "profile parameter boundary rejects scalars nested lists and mass assignment" do
    payloads = [
      { workflow_profile: "bad" },
      { workflow_profile: profile_params.merge(translator_ids: "1") },
      { workflow_profile: profile_params.merge(reviewer_ids: [ { nested: "1" } ]) },
      { workflow_profile: profile_params.merge(user_id: users(:other).id) },
      { workflow_profile: profile_params.merge(active: "0") },
      { workflow_profile: profile_params.merge(role: "admin") }
    ]
    payloads.each do |payload|
      assert_no_difference -> { WorkflowProfile.count } do
        post workflow_profiles_path, params: payload
      end
      assert_response :bad_request
    end
  end

  test "automatic workspace launch requires exact profile authorization and creates one pipeline" do
    profile = create_workflow_profile
    assert_difference -> { PipelineRun.count }, 1 do
      assert_difference -> { Experiment.count }, 1 do
        assert_enqueued_jobs 2, only: TranslationRunJob do
          post translation_workspace_path, params: {
            translation_workspace: workspace_params.merge(
              workflow_mode: "automatic",
              workflow_profile_revision_id: profile.current_revision_id.to_s,
              automatic_confirmation: "1"
            )
          }
        end
      end
    end
    pipeline = PipelineRun.order(:id).last
    assert_redirected_to pipeline_run_path(pipeline)
    assert_equal profile.current_revision, pipeline.workflow_profile_revision
    assert_equal 4, pipeline.authorized_initial_provider_run_count
  end

  test "automatic launch rejects missing confirmation mixed manual IDs stale revision and other owner" do
    profile = create_workflow_profile
    base = workspace_params.merge(
      workflow_mode: "automatic",
      workflow_profile_revision_id: profile.current_revision_id.to_s,
      automatic_confirmation: "0"
    )
    assert_no_automatic_records { post translation_workspace_path, params: { translation_workspace: base } }
    assert_response :unprocessable_content
    assert_select "li", text: /confirmation.*accepted/i

    assert_no_automatic_records do
      post translation_workspace_path, params: {
        translation_workspace: base.merge(
          automatic_confirmation: "1",
          model_ids: [ llm_models(:openrouter_claude).id.to_s ]
        )
      }
    end
    assert_response :unprocessable_content
    assert_select "li", text: /cannot mix/

    old_revision = profile.current_revision
    WorkflowProfiles::Revise.call(
      workflow_profile: profile,
      expected_version: 1,
      attributes: workflow_profile_attributes(name: "New revision")
    )
    assert_no_automatic_records do
      post translation_workspace_path, params: {
        translation_workspace: base.merge(
          automatic_confirmation: "1",
          workflow_profile_revision_id: old_revision.id.to_s
        )
      }
    end
    assert_response :unprocessable_content
    assert_select "li", text: /stale/

    other = create_workflow_profile(user: users(:other))
    assert_no_automatic_records do
      post translation_workspace_path, params: {
        translation_workspace: base.merge(
          automatic_confirmation: "1",
          workflow_profile_revision_id: other.current_revision_id.to_s
        )
      }
    end
    assert_response :unprocessable_content
    assert_select "li", text: /not available/
  end

  test "workspace and stop parameter shapes reject tampering without a 500" do
    profile = create_workflow_profile
    malformed = [
      workspace_params.merge(workflow_mode: "automatic", workflow_profile_revision_id: [ profile.current_revision_id ], automatic_confirmation: "1"),
      workspace_params.merge(workflow_mode: "automatic", workflow_profile_revision_id: profile.current_revision_id.to_s, automatic_confirmation: [ "1" ]),
      workspace_params.merge(workflow_mode: "automatic", workflow_profile_revision_id: profile.current_revision_id.to_s, automatic_confirmation: "1", user_id: users(:other).id)
    ]
    malformed.each do |attributes|
      assert_no_automatic_records { post translation_workspace_path, params: { translation_workspace: attributes } }
      assert_response :bad_request
    end

    pipeline = launch_pipeline(profile)
    patch stop_pipeline_run_path(pipeline), params: { pipeline_run: "bad" }
    assert_response :bad_request
    assert pipeline.reload.running?
  end

  test "pipeline progress is owner scoped and stop is explicit and non-destructive" do
    pipeline = launch_pipeline(create_workflow_profile)
    get pipeline_run_path(pipeline)
    assert_response :success
    assert_select "h1", pipeline.workflow_profile_revision.name
    assert_select "h2", text: /Progress/
    assert_select "h2", text: /Known provider cost/
    assert_select "form[action='#{stop_pipeline_run_path(pipeline)}']"

    patch stop_pipeline_run_path(pipeline)
    assert_redirected_to pipeline_run_path(pipeline)
    assert pipeline.reload.stopped?
    assert_equal 2, pipeline.experiment.translation_runs.count

    sign_out
    sign_in_as users(:other)
    get pipeline_run_path(pipeline)
    assert_response :not_found
  end

  test "manual workspace remains first class and creates no pipeline" do
    assert_no_difference -> { PipelineRun.count } do
      post translation_workspace_path, params: {
        translation_workspace: workspace_params.merge(
          workflow_mode: "manual",
          model_ids: [ llm_models(:openrouter_claude).id.to_s ]
        )
      }
    end
    assert_redirected_to experiment_path(Experiment.order(:id).last)
  end

  private

  def profile_params
    workflow_profile_attributes(name: "Browser profile").transform_values do |value|
      value.is_a?(Array) ? value.map(&:to_s) : value.to_s
    end
  end

  def workspace_params
    {
      project_name: "Automatic browser project",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Automatic source",
      source_text: "Source text",
      experiment_name: "Automatic experiment",
      instruction_prompt: "Translate faithfully."
    }
  end

  def assert_no_automatic_records
    before = [ Project.count, Document.count, Experiment.count, PipelineRun.count, TranslationRun.count ]
    yield
    assert_equal before, [ Project.count, Document.count, Experiment.count, PipelineRun.count, TranslationRun.count ]
  end

  def launch_pipeline(profile)
    post translation_workspace_path, params: {
      translation_workspace: workspace_params.merge(
        workflow_mode: "automatic",
        workflow_profile_revision_id: profile.current_revision_id.to_s,
        automatic_confirmation: "1"
      )
    }
    PipelineRun.order(:id).last
  end
end
