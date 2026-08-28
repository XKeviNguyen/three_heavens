require "test_helper"
require_relative "../support/authorized_ai_job_helper"

class AiJobLineageTest < ActiveJob::TestCase
  include ActiveJob::TestHelper
  include AuthorizedAiJobHelper

  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Job lineage race",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Source", source_text: "Source text")
    @experiment = document.experiments.create!(instruction_prompt: "Translate.")
    @run = TranslationExperiments::Start.call(
      experiment: @experiment,
      llm_models: [ llm_models(:openrouter_claude) ]
    ).first
    clear_enqueued_jobs
  end

  test "obsolete built in retry cannot steal a manually recovered scheduling cycle or overwrite its result" do
    old_job_id = @run.scheduled_job_id
    retrying_client = Object.new
    retrying_client.define_singleton_method(:chat_completion) do |**|
      raise Ai::OpenRouterClient::RetryableError.new("Busy", code: "provider_busy")
    end

    with_client(retrying_client) do
      assert_enqueued_with(job: TranslationRunJob, args: [ @run.id ]) do
        perform_authorized_ai_job(TranslationRunJob, @run)
      end
    end
    old_attempt = @run.reload.execution_attempt
    assert_equal 1, old_attempt
    assert @run.running?
    clear_enqueued_jobs

    @run.update!(last_claimed_at: 3.hours.ago)
    assert_equal 1, Ai::StaleExecutionReconciler.call.total
    assert @run.reload.failed?

    assert_enqueued_with(job: TranslationRunJob, args: [ @run.id ]) do
      assert_equal 1, TranslationExperiments::RetryFailed.call(@experiment).retried_count
    end
    new_job_id = @run.reload.scheduled_job_id
    assert_not_equal old_job_id, new_job_id
    assert @run.pending?
    clear_enqueued_jobs

    calls = 0
    old_retry = build_authorized_ai_job(
      TranslationRunJob,
      @run,
      job_id: old_job_id,
      execution: 2
    )
    with_client(counting_success_client(-> { calls += 1 })) do
      old_retry.perform_now
    end
    assert_equal 0, calls
    assert @run.reload.pending?

    result = successful_result
    racing_client = Object.new
    racing_client.define_singleton_method(:chat_completion) do |**|
      calls += 1
      old_retry.perform_now
      result
    end
    with_client(racing_client) do
      perform_authorized_ai_job(TranslationRunJob, @run)
    end

    assert_equal 1, calls
    assert @run.reload.completed?
    assert_equal new_job_id, @run.scheduled_job_id
    assert_equal 1, @run.claimed_job_execution
    assert_equal old_attempt + 1, @run.execution_attempt
    assert_equal "Recovered translation", @run.translated_text

    late_error = Ai::OpenRouterClient::PermanentError.new("Late old result", code: "late")
    assert_not Ai::RunResult.persist_failure(@run, error: late_error, attempt: old_attempt)
    assert @run.reload.completed?
    assert_equal "Recovered translation", @run.translated_text
  end

  private

  def with_client(client)
    original = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }
    yield
  ensure
    TranslationRunJob.client_factory = original
  end

  def counting_success_client(counter)
    result = successful_result
    Object.new.tap do |client|
      client.define_singleton_method(:chat_completion) do |**|
        counter.call
        result
      end
    end
  end

  def successful_result
    Ai::OpenRouterClient::Result.new(
      content: "Recovered translation",
      provider_response_id: nil,
      resolved_model_identifier: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      cached_tokens: nil,
      reasoning_tokens: nil,
      cost: nil
    )
  end
end
