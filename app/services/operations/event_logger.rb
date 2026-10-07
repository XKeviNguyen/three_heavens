require "json"

module Operations
  class EventLogger
    class InvalidEvent < StandardError; end

    COMMON_FIELDS = %i[
      request_id active_job_id scheduled_job_id execution_attempt run_type run_id
      experiment_id pipeline_run_id pipeline_stage status error_code duration_ms
      count outcome user_id actor_id
    ].freeze
    EVENTS = %w[
      workspace_launch_succeeded workspace_launch_replayed ai_run_scheduled
      ai_execution_claimed ai_run_completed ai_run_failed pipeline_stage_advanced
      pipeline_blocked pipeline_ready_for_editor stale_reconciliation_completed
      pipeline_reconciliation_completed source_import_cleanup_completed
      workspace_submission_cleanup_completed active_storage_cleanup_completed
      source_import_retirement_cleanup_completed workspace_draft_cleanup_completed
      workspace_editor_cleanup_completed reference_recovery_cleanup_completed reference_identity_cleanup_completed
      managed_ai_access_changed backup_started backup_completed
      backup_failed restore_verification_started restore_verification_completed
      restore_verification_failed operations_preflight_completed
    ].index_with { COMMON_FIELDS }.freeze
    SEVERITIES = %i[debug info warn error].freeze
    SAFE_TOKEN = /\A[a-z0-9][a-z0-9_.:-]{0,79}\z/
    SAFE_IDENTIFIER = /\A[A-Za-z0-9_-]{1,100}\z/
    SAFE_ERROR_CODES = %w[
      enqueue_failed invalid_response malformed_json missing_api_key
      model_unavailable network_error provider_failure stale_execution
      stale_pending managed_ai_access_revoked configuration_unavailable stage_failed stage_conflict reference_context_budget
    ].freeze
    INTEGER_FIELDS = %i[execution_attempt run_id experiment_id pipeline_run_id duration_ms count user_id actor_id].freeze
    TOKEN_FIELDS = %i[run_type pipeline_stage status error_code outcome].freeze
    IDENTIFIER_FIELDS = %i[request_id active_job_id scheduled_job_id].freeze

    def self.emit(event, severity: :info, logger: Rails.logger, at: Time.current, **fields)
      new(logger: logger).emit(event, severity: severity, at: at, fields: fields)
    end

    def initialize(logger: Rails.logger)
      @logger = logger
    end

    def emit(event, severity:, at:, fields:)
      event_name = event.to_s
      allowed = EVENTS[event_name]
      raise InvalidEvent, "unknown operational event" unless allowed
      raise InvalidEvent, "invalid severity" unless severity.to_sym.in?(SEVERITIES)

      unknown = fields.keys.map(&:to_sym) - allowed
      raise InvalidEvent, "unknown operational fields" if unknown.any?

      payload = {
        timestamp: at.utc.iso8601(6),
        severity: severity.to_s,
        event: event_name
      }
      fields.each { |key, value| payload[key] = safe_value!(key.to_sym, value) unless value.nil? }
      logger.public_send(severity, JSON.generate(payload))
      payload
    end

    private

    attr_reader :logger

    def safe_value!(field, value)
      if INTEGER_FIELDS.include?(field)
        integer = Integer(value)
        raise InvalidEvent, "integer field is outside its allowed range" unless integer.between?(0, 9_223_372_036_854_775_807)

        integer
      elsif field == :error_code
        string = value.to_s
        unless SAFE_ERROR_CODES.include?(string) || string.match?(/\A(?:http_)?[45][0-9]{2}\z/)
          raise InvalidEvent, "unsafe error code"
        end

        string
      elsif TOKEN_FIELDS.include?(field)
        string = value.to_s
        raise InvalidEvent, "unsafe token field" unless SAFE_TOKEN.match?(string)

        string
      elsif IDENTIFIER_FIELDS.include?(field)
        string = value.to_s
        raise InvalidEvent, "unsafe identifier field" unless SAFE_IDENTIFIER.match?(string)

        string
      else
        raise InvalidEvent, "unsupported operational field"
      end
    rescue ArgumentError, TypeError
      raise InvalidEvent, "invalid operational field value"
    end
  end
end
