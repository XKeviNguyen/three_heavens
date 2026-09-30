require "securerandom"
require "yaml"

module Operations
  class Preflight
    Check = Data.define(:name, :status, :critical)
    Result = Data.define(:checks) do
      def successful?
        checks.none? { |check| check.critical && check.status != "healthy" }
      end
    end

    REQUIRED_ENVIRONMENT_NAMES = %w[
      APP_HOST RAILS_MASTER_KEY DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL
      CABLE_DATABASE_URL OPENROUTER_API_KEY MAIL_FROM SMTP_HOST SMTP_USERNAME SMTP_PASSWORD
    ].freeze

    def self.call(**options)
      new(**options).call
    end

    def initialize(environment: ENV, system_health: -> { Operations::SystemHealth.call },
                   executable_finder: nil, migration_check: nil, recurring_path: Rails.root.join("config/recurring.yml"),
                   recurring_validator: nil, queue_adapter: -> { ActiveJob::Base.queue_adapter_name },
                   eager_load_check: -> { Rails.application.eager_load! })
      @environment = environment
      @system_health = system_health
      @executable_finder = executable_finder || method(:executable?)
      @migration_check = migration_check || -> { !ActiveRecord::Base.connection_pool.migration_context.needs_migration? }
      @recurring_path = recurring_path
      @recurring_validator = recurring_validator || method(:valid_recurring_task?)
      @queue_adapter = queue_adapter
      @eager_load_check = eager_load_check
    end

    def call
      checks = []
      checks << check("required_environment", critical: true) { required_environment_present? }
      system_health.call.checks.each do |dependency|
        checks << Check.new(name: dependency.name, status: dependency.status, critical: true)
      end
      checks << check("storage_write_probe", critical: true) { storage_write_probe }
      checks << check("pg_dump", critical: true) { executable_finder.call("pg_dump") }
      checks << check("pg_restore", critical: true) { executable_finder.call("pg_restore") }
      checks << check("schema_migrations", critical: true) { migration_check.call }
      checks << check("queue_adapter", critical: true) { queue_adapter.call.to_s == "solid_queue" }
      checks << check("recurring_schedule", critical: true) { recurring_schedule_valid? }
      checks << check("eager_load", critical: true) { eager_load_check.call; true }
      if environment["BACKUP_DESTINATION_ROOT"].present?
        checks << check("backup_destination", critical: true) { backup_destination_ready? }
      end
      result = Result.new(checks: checks.freeze)
      Operations::EventLogger.emit(
        "operations_preflight_completed",
        severity: result.successful? ? :info : :error,
        outcome: result.successful? ? "success" : "failed",
        count: checks.count { |entry| entry.status != "healthy" }
      )
      result
    end

    private

    attr_reader :eager_load_check, :environment, :executable_finder, :migration_check,
                :queue_adapter, :recurring_path, :recurring_validator, :system_health

    def check(name, critical:)
      Check.new(name: name, status: yield ? "healthy" : "unavailable", critical: critical)
    rescue StandardError
      Check.new(name: name, status: "unavailable", critical: critical)
    end

    def required_environment_present?
      REQUIRED_ENVIRONMENT_NAMES.all? { |name| environment[name].present? }
    end

    def executable?(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, name)
        File.file?(path) && File.executable?(path)
      end
    end

    def recurring_schedule_valid?
      parsed = YAML.safe_load_file(recurring_path, aliases: false)
      production = parsed.fetch("production")
      production.is_a?(Hash) && production.any? && production.values.all? do |entry|
        next false unless entry.is_a?(Hash)

        recurring_validator.call("preflight", entry.deep_symbolize_keys)
      end
    end

    def valid_recurring_task?(key, entry)
      SolidQueue::RecurringTask.from_configuration(key, **entry).valid?
    end

    def storage_write_probe
      service = ActiveStorage::Blob.service
      return false unless service.respond_to?(:root)

      root = Operations::PathSafety.prepare_root!(service.root)
      probe = Operations::PathSafety.child!(root, ".operations-preflight-#{SecureRandom.hex(12)}")
      File.open(probe, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("")
        file.flush
        file.fsync
      end
      true
    ensure
      File.delete(probe) if defined?(probe) && probe&.file? && !probe.symlink?
    end

    def backup_destination_ready?
      root = Operations::PathSafety.prepare_root!(environment.fetch("BACKUP_DESTINATION_ROOT"))
      File.writable?(root)
    end
  end
end
