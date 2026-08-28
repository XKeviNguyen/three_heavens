require "test_helper"

class Ai::ExecutionClaimTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Execution lineage",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :running)
    @run = experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      scheduled_job_id: "authorized-job",
      pending_since: Time.current
    )
  end

  test "only strictly newer executions in the authorized Active Job lineage may claim" do
    first = claim(job_id: "authorized-job", execution: 1)
    assert_equal :claimed, first.state
    assert_equal 1, first.attempt
    assert_equal 1, @run.reload.claimed_job_execution

    duplicate_first = claim(job_id: "authorized-job", execution: 1)
    assert_equal :duplicate_running, duplicate_first.state
    assert_equal 1, @run.reload.execution_attempt

    retry_claim = claim(job_id: "authorized-job", execution: 2)
    assert_equal :claimed, retry_claim.state
    assert_equal 2, retry_claim.attempt
    assert_equal 2, @run.reload.claimed_job_execution

    duplicate_retry = claim(job_id: "authorized-job", execution: 2)
    assert_equal :duplicate_running, duplicate_retry.state
    assert_equal 2, @run.reload.execution_attempt

    foreign_job = claim(job_id: "different-job", execution: 3)
    assert_equal :obsolete, foreign_job.state
    assert_equal 2, @run.reload.execution_attempt
  end

  test "pending work rejects an obsolete job before any claim" do
    result = claim(job_id: "obsolete-job", execution: 1)

    assert_equal :obsolete, result.state
    assert @run.reload.pending?
    assert_equal 0, @run.execution_attempt
    assert_equal "authorized-job", @run.scheduled_job_id
  end

  private

  def claim(job_id:, execution:)
    Ai::ExecutionClaim.call(
      @run,
      active_job_id: job_id,
      active_job_execution: execution
    )
  end
end
