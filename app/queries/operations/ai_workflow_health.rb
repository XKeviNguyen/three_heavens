module Operations
  class AiWorkflowHealth
    RUN_TYPES = {
      "Translations" => TranslationRun,
      "Reviews" => ReviewRun,
      "Judgments" => JudgeRun,
      "Finalizations" => FinalizationRun
    }.freeze
    STATUSES = %w[pending running failed].freeze
    FAILURE_WINDOW = 7.days
    FAILURE_LIMIT = 20
    SAFE_FAILURE_CODES = %w[
      enqueue_failed invalid_response malformed_json missing_api_key model_unavailable
      network_error provider_failure stale_execution stale_pending
    ].freeze
    HTTP_FAILURE_CODE = /\A(?:http_)?([45]\d{2})\z/

    Snapshot = Data.define(:workflows, :failure_codes, :stale_threshold_minutes)

    def self.call(now: Time.current)
      cutoff = Ai::StaleExecutionPolicy.cutoff(now: now)
      workflows = RUN_TYPES.map do |label, run_class|
        counts = run_class.where(status: STATUSES).group(:status).count
        {
          label: label,
          counts: STATUSES.index_with { |status| counts.fetch(status, 0) },
          stale_running_count: run_class.running.where(last_claimed_at: ..cutoff).count,
          stale_pending_count: run_class.pending.where(pending_since: ..cutoff).count,
          oldest_active_at: run_class.where(status: %w[pending running]).minimum(:created_at)
        }
      end

      failure_codes = RUN_TYPES.flat_map do |label, run_class|
        run_class.failed
          .where(completed_at: (now - FAILURE_WINDOW)..now)
          .where.not(error_code: [ nil, "" ])
          .group(:error_code)
          .order(Arel.sql("COUNT(*) DESC"))
          .limit(FAILURE_LIMIT)
          .count
          .each_with_object(Hash.new(0)) do |(code, count), safe_counts|
            safe_counts[safe_failure_code(code)] += count
          end
          .map { |code, count| { workflow: label, code: code, count: count } }
      end.sort_by { |entry| [ -entry.fetch(:count), entry.fetch(:workflow), entry.fetch(:code) ] }
        .first(FAILURE_LIMIT)

      Snapshot.new(
        workflows: workflows.freeze,
        failure_codes: failure_codes.freeze,
        stale_threshold_minutes: (Ai::StaleExecutionPolicy.threshold / 1.minute).to_i
      )
    end

    def self.safe_failure_code(code)
      code = code.to_s
      return code if code.in?(SAFE_FAILURE_CODES)

      http_status = HTTP_FAILURE_CODE.match(code)&.captures&.first
      http_status ? "http_#{http_status}" : "provider_failure"
    end
    private_class_method :safe_failure_code
  end
end
