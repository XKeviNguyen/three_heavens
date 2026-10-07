require "test_helper"

class OperationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Operations privacy",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(
      title: "Never render private marker",
      source_text: "PRIVATE_SOURCE_MARKER"
    )
    @experiment = document.experiments.create!(
      instruction_prompt: "PRIVATE_PROMPT_MARKER",
      status: :running
    )
    @run = @experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :failed,
      error_code: "PRIVATE_FAILURE_CODE_MARKER",
      error_message: "PRIVATE_ERROR_BODY_MARKER",
      completed_at: Time.current
    )
    TranslationExperiments::ReconcileExperiment.call(@experiment)
    clear_enqueued_jobs
  end

  test "admin sees bounded aggregate health without private workflow content" do
    sign_in_as users(:admin)

    get settings_operations_path

    assert_response :success
    assert_select "h1", "AI workflow operations"
    assert_select "h2", "Production system diagnostics"
    assert_select "td", text: "1", minimum: 1
    assert_select "span.font-mono", text: "provider_failure"
    assert_not_includes response.body, "PRIVATE_SOURCE_MARKER"
    assert_not_includes response.body, "PRIVATE_PROMPT_MARKER"
    assert_not_includes response.body, "PRIVATE_ERROR_BODY_MARKER"
    assert_not_includes response.body, "PRIVATE_FAILURE_CODE_MARKER"
    assert_not_includes response.body, "DATABASE_URL"
    assert_not_includes response.body, "/rails/storage"
  end

  test "normal users are denied both visibility and reconciliation server side" do
    sign_in_as users(:normal)

    get settings_operations_path
    assert_redirected_to root_path

    assert_no_changes -> { @run.reload.status } do
      post reconcile_stale_settings_operations_path
      assert_redirected_to root_path
    end
    assert_no_enqueued_jobs
  end

  test "admin reconciliation action is explicit idempotent and starts no provider work" do
    sign_in_as users(:admin)

    assert_no_enqueued_jobs do
      post reconcile_stale_settings_operations_path
    end

    assert_redirected_to settings_operations_path
    follow_redirect!
    assert_select "[role='status']", text: /No AI requests were sent/
  end
end
