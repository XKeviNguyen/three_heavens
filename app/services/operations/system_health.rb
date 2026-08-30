module Operations
  class SystemHealth
    MAX_QUEUE_METRIC = 1_000_000
    Check = Data.define(:name, :status, :metrics)
    Snapshot = Data.define(:checks) do
      def status
        return "unavailable" if checks.any? { |check| check.status == "unavailable" }
        return "degraded" if checks.any? { |check| check.status == "degraded" }

        "healthy"
      end
    end

    def self.call(**options)
      new(**options).call
    end

    def initialize(
      primary_check: -> { ActiveRecord::Base.connection.select_value("SELECT 1") },
      cache_check: -> { SolidCache::Entry.connection.select_value("SELECT 1") },
      queue_check: -> { queue_metrics },
      cable_check: -> { SolidCable::Message.connection.select_value("SELECT 1") },
      storage_check: -> { storage_metrics }
    )
      @checks = {
        "primary_database" => primary_check,
        "cache_database" => cache_check,
        "queue_database" => queue_check,
        "cable_database" => cable_check,
        "active_storage" => storage_check
      }
    end

    def call
      Snapshot.new(checks: checks.map { |name, callable| run_check(name, callable) }.freeze)
    end

    private

    attr_reader :checks

    def run_check(name, callable)
      result = callable.call
      status = result.is_a?(Hash) ? result[:status] || result["status"] || "healthy" : "healthy"
      metrics = result.is_a?(Hash) ? sanitize_metrics(result) : {}
      status = "degraded" unless status.in?(%w[healthy degraded unavailable])
      Check.new(name: name, status: status, metrics: metrics.freeze)
    rescue StandardError
      Check.new(name: name, status: "unavailable", metrics: {}.freeze)
    end

    def sanitize_metrics(metrics)
      allowed = %i[pending_count failed_count writable configured]
      metrics.slice(*allowed).to_h do |key, value|
        safe_value = if key.in?(%i[writable configured])
          value == true
        else
          Integer(value).clamp(0, MAX_QUEUE_METRIC)
        end
        [ key, safe_value ]
      end
    end

    def queue_metrics
      {
        pending_count: SolidQueue::ReadyExecution.limit(MAX_QUEUE_METRIC + 1).count,
        failed_count: SolidQueue::FailedExecution.limit(MAX_QUEUE_METRIC + 1).count
      }
    end

    def storage_metrics
      service = ActiveStorage::Blob.service
      return { configured: true, writable: false, status: "degraded" } unless service.respond_to?(:root)

      root = Pathname.new(service.root.to_s)
      writable = root.directory? && !root.symlink? && File.writable?(root)
      { configured: true, writable: writable, status: writable ? "healthy" : "degraded" }
    end
  end
end
