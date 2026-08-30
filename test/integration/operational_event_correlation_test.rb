require "test_helper"

class OperationalEventCorrelationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "workspace request durable experiment and scheduled job share safe correlation fields" do
    sign_in_as users(:normal)
    events = []
    emitter = lambda do |event, **fields|
      events << [ event, fields ]
      fields
    end
    token = issue_translation_workspace_token

    original_emitter = Operations::EventLogger.method(:emit)
    Operations::EventLogger.define_singleton_method(:emit, emitter)
    begin
      assert_enqueued_jobs 1, only: TranslationRunJob do
        post translation_workspace_path, params: {
          translation_workspace: {
            project_name: "Correlation project",
            source_language: "Vietnamese",
            target_language: "Japanese",
            document_title: "Correlation document",
            source_text: "private source that must not be logged",
            experiment_name: "Correlation experiment",
            instruction_prompt: "private prompt that must not be logged",
            model_ids: [ llm_models(:openrouter_claude).id.to_s ],
            workflow_mode: "manual",
            submission_token: token
          }
        }
      end
    ensure
      Operations::EventLogger.define_singleton_method(:emit, original_emitter)
    end

    experiment = Experiment.order(:id).last
    run = experiment.translation_runs.sole
    scheduled = events.find { |event, _fields| event == "ai_run_scheduled" }.second
    launched = events.find { |event, _fields| event == "workspace_launch_succeeded" }.second
    assert_equal experiment.id, scheduled.fetch(:experiment_id)
    assert_equal experiment.id, launched.fetch(:experiment_id)
    assert_equal run.id, scheduled.fetch(:run_id)
    assert_equal run.scheduled_job_id, scheduled.fetch(:scheduled_job_id)
    assert launched.fetch(:request_id).match?(Operations::EventLogger::SAFE_IDENTIFIER)
    serialized = events.inspect
    assert_not_includes serialized, "private source"
    assert_not_includes serialized, "private prompt"
  end
end
