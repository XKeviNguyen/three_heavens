require "test_helper"
require_relative "../support/workflow_profile_test_helper"

class RepeatExperimentTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
    @project = users(:normal).projects.create!(
      name: "Reusable project",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = @project.documents.create!(title: "Original source", source_text: "Xin chào")
    @historical = document.experiments.create!(
      name: "Original experiment",
      instruction_prompt: "Translate faithfully.",
      guidance_preference: :reference_examples,
      status: :completed
    )
    @historical.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :completed,
      translated_text: "Hello",
      completed_at: Time.current
    )
  end

  test "GET prefills a new reviewed launch and POST creates new identities with explicit paid work" do
    assert_no_difference [ -> { Experiment.count }, -> { enqueued_jobs.size } ] do
      get repeat_experiment_path(@historical)
    end
    assert_response :success
    assert_select "input[name='translation_workspace[submission_token]']", count: 1
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Xin chào"
    assert_select "input[name='translation_workspace[model_ids][]'][value='#{llm_models(:openrouter_claude).id}'][checked]"
    token = css_select("input[name='translation_workspace[submission_token]']").first["value"]

    assert_difference -> { Experiment.count }, 1 do
      assert_enqueued_jobs 1, only: TranslationRunJob do
        post translation_workspace_path, params: {
          translation_workspace: {
            submission_token: token,
            project_id: @project.id,
            document_title: "Original source",
            source_text: "Xin chào",
            experiment_name: "Repeat of Original experiment",
            instruction_prompt: "Translate faithfully.",
            guidance_preference: "reference_examples",
            workflow_mode: "manual",
            model_ids: [ llm_models(:openrouter_claude).id ]
          }
        }
      end
    end

    repeated = Experiment.order(:id).last
    assert_not_equal @historical.id, repeated.id
    assert_equal @historical.instruction_prompt, repeated.instruction_prompt
    assert_equal "Original experiment", @historical.reload.name
  end

  test "repeat is owner scoped" do
    other = experiments(:two)
    get repeat_experiment_path(other)
    assert_response :not_found
  end

  test "long automatic history with unavailable capabilities falls back to a usable manual prefill" do
    @historical.document.update!(source_text: "Long paragraph。\n\n" * 500)
    @historical.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :completed,
      translated_text: "Second translation",
      completed_at: Time.current
    )
    profile = create_workflow_profile
    create_pipeline_run(experiment: @historical, profile: profile)

    assert_no_enqueued_jobs do
      get repeat_experiment_path(@historical)
    end

    assert_response :success
    assert_select "[role='status']", text: /no longer has the model capability data/
    assert_select "input[name='translation_workspace[workflow_mode]'][value='manual'][checked]"
    assert_select "input[name='translation_workspace[workflow_profile_revision_id]'][checked]", count: 0
    assert_select "input[name='translation_workspace[model_ids][]'][checked]", count: 2
  end
end
