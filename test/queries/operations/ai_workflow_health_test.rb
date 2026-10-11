require "test_helper"

class Operations::AiWorkflowHealthTest < ActiveSupport::TestCase
  test "billing denials keep their codes so operators see account and key problems, not provider outages" do
    project = users(:normal).projects.create!(name: "Health", source_language: "Vietnamese", target_language: "Japanese")
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(instruction_prompt: "Translate.")
    codes = %w[ai_account_ineligible managed_ai_access_revoked personal_key_unavailable]
    models = codes.map do |code|
      LlmModel.create!(gateway: "openrouter", provider: "health", model_identifier: "health/#{code}", display_name: code)
    end
    codes.zip(models).each do |code, model|
      experiment.translation_runs.create!(llm_model: model, status: :failed, completed_at: Time.current,
                                          error_code: code, error_message: "denied")
    end

    reported = Operations::AiWorkflowHealth.call.failure_codes.map { |entry| entry.fetch(:code) }

    assert_empty codes - reported
    assert_not_includes reported, "provider_failure"
  end
end
