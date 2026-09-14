require "test_helper"

class Pipelines::ExecutionSummaryTest < ActiveSupport::TestCase
  test "counts logical work physical work and actual attempts without counting both parent and segments" do
    project = users(:normal).projects.create!(name: "Progress", source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Source", source_text: "Source")
    experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :running)
    completed = experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      scheduled_job_id: "job-one",
      pending_since: Time.current
    )
    experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      scheduled_job_id: "job-two",
      pending_since: Time.current
    )

    claim = Ai::ExecutionClaim.call(completed, active_job_id: "job-one", active_job_execution: 1)
    assert_equal :claimed, claim.state
    completed.update!(
      status: :completed,
      translated_text: "Translation",
      completed_at: Time.current,
      total_tokens: 42,
      cost: BigDecimal("0")
    )

    result = Pipelines::ExecutionSummary.call(experiment: experiment)

    assert_equal 2, result.logical_total
    assert_equal 2, result.physical_total
    assert_equal({ "completed" => 1, "pending" => 1 }, result.logical_status_counts)
    assert_equal 1, result.attempt_total
    assert_equal 42, result.known_total_tokens
    assert_equal BigDecimal("0"), result.known_cost
    assert_not result.cost_telemetry_incomplete?
  end
end
