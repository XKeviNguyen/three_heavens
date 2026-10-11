module Ai
  class RetryFailedRuns
    class Error < StandardError; end
    class UnsupportedModelError < Error; end

    # enqueued_count is read from the enqueue outcomes when asked, so a caller
    # that ran the retry inside its own transaction (to hold the owner's lock
    # while stamping, Ai::BillingPolicy.authorize_confirmed!) sees the actual
    # result once that transaction has committed.
    Result = Data.define(:retried_count, :enqueue_outcomes) do
      def enqueued_count = enqueue_outcomes.count(&:accepted?)
    end

    # billing: the authorization for this explicit retry, which may differ from
    # the one the failed attempt ran under (Ai::BillingPolicy).
    def self.call(parent:, runs_association:, model_association:, job_class:, prepare_parent:, billing:,
                  prepare_run: nil, lock_before: nil)
      retried_runs = []
      schedules = []

      parent.class.transaction do
        lock_before&.lock!
        parent.lock!
        runs = parent.public_send(runs_association).lock.to_a
        retried_runs = runs.select(&:failed?)
        next if retried_runs.empty?

        validate_models!(retried_runs, model_association)
        prepare_parent.call(parent, retried_runs)
        retried_runs.each do |run|
          prepare_run&.call(run)
          run.update!(retry_attributes(run))
          schedules << RunScheduler.prepare(run: run, job_class: job_class, billing: billing)
        end
      end
      Result.new(retried_count: retried_runs.size, enqueue_outcomes: RunScheduler.enqueue_outcomes(schedules))
    end

    def self.validate_models!(runs, model_association)
      unsupported = runs.reject do |run|
        model = run.public_send(model_association)
        model&.active? && model.gateway == "openrouter"
      end
      return if unsupported.empty?

      raise UnsupportedModelError,
            "Retry is unavailable because one or more historical models are inactive or unsupported. Ask an administrator to restore the original model."
    end
    private_class_method :validate_models!

    def self.retry_attributes(run)
      attributes = {
        status: :pending,
        completed_at: nil,
        pending_since: nil,
        last_claimed_at: nil,
        error_code: nil,
        error_message: nil,
        provider_response_id: nil,
        resolved_model_identifier: nil,
        prompt_tokens: nil,
        completion_tokens: nil,
        total_tokens: nil,
        cached_tokens: nil,
        reasoning_tokens: nil,
        cost: nil
      }
      attributes[:translated_text] = nil if run.is_a?(TranslationRun)
      attributes[:telemetry_complete] = false if run.respond_to?(:telemetry_complete)
      attributes[:cost_complete] = false if run.respond_to?(:cost_complete)
      if run.is_a?(JudgeRun)
        attributes.merge!(
          winner_translation_run_id: nil,
          winner_rationale: nil,
          confidence_score: nil
        )
      elsif run.is_a?(FinalizationRun)
        attributes.merge!(
          proposed_translation: nil,
          change_summary: [],
          terminology_notes: [],
          warnings: []
        )
      end
      attributes
    end
  end
end
