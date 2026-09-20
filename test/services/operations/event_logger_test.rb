require "test_helper"
require "json"
require "stringio"

class Operations::EventLoggerTest < ActiveSupport::TestCase
  class CapturingLogger
    attr_reader :entries

    def initialize
      @entries = []
    end

    %i[debug info warn error].each do |severity|
      define_method(severity) { |message| entries << [ severity, message ] }
    end
  end

  test "emits one-line JSON containing only fixed safe fields" do
    logger = CapturingLogger.new

    payload = Operations::EventLogger.emit(
      "ai_execution_claimed",
      logger: logger,
      at: Time.utc(2026, 8, 30),
      active_job_id: "job_123",
      execution_attempt: 2,
      run_type: "translation_run",
      run_id: 42,
      experiment_id: 7,
      status: "running"
    )

    severity, line = logger.entries.fetch(0)
    parsed = JSON.parse(line)
    assert_equal :info, severity
    assert_equal payload.stringify_keys, parsed
    assert_equal 1, line.lines.size
    assert_equal %w[active_job_id event execution_attempt experiment_id run_id run_type severity status timestamp], parsed.keys.sort
  end

  test "rejects arbitrary metadata and every sensitive-shaped value" do
    logger = CapturingLogger.new
    sensitive_values = [
      "sk-or-v1-SYNTHETICSECRET",
      "Bearer synthetic-token",
      "postgresql://user:password@private-db/database",
      "private source text with spaces",
      "user@example.test",
      "original-private-file.docx",
      "{provider_error_body:true}"
    ]

    assert_raises(Operations::EventLogger::InvalidEvent) do
      Operations::EventLogger.emit("ai_run_failed", logger: logger, metadata: { params: "private" })
    end
    sensitive_values.each do |value|
      assert_raises(Operations::EventLogger::InvalidEvent) do
        Operations::EventLogger.emit("ai_run_failed", logger: logger, error_code: value)
      end
    end
    assert_empty logger.entries
  end

  test "rejects unknown event names and unbounded identifiers" do
    logger = CapturingLogger.new

    assert_raises(Operations::EventLogger::InvalidEvent) do
      Operations::EventLogger.emit("user_supplied_event", logger: logger, outcome: "success")
    end
    assert_raises(Operations::EventLogger::InvalidEvent) do
      Operations::EventLogger.emit("ai_run_scheduled", logger: logger, active_job_id: "x" * 101)
    end
  end
end
