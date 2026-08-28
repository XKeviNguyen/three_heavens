module Ai
  class StaleExecutionPolicy
    ENVIRONMENT_KEY = "AI_STALE_EXECUTION_THRESHOLD_MINUTES"
    DEFAULT_THRESHOLD = 2.hours
    MINIMUM_THRESHOLD = 15.minutes
    MAXIMUM_THRESHOLD = 24.hours

    def self.threshold
      raw_minutes = ENV[ENVIRONMENT_KEY]
      return DEFAULT_THRESHOLD if raw_minutes.blank?

      minutes = Integer(raw_minutes, 10)
      threshold = minutes.minutes
      unless threshold.between?(MINIMUM_THRESHOLD, MAXIMUM_THRESHOLD)
        raise ArgumentError,
              "#{ENVIRONMENT_KEY} must be between 15 and 1440 minutes"
      end

      threshold
    rescue ArgumentError => error
      raise ArgumentError,
            "Invalid #{ENVIRONMENT_KEY}: #{error.message}"
    end

    def self.cutoff(now: Time.current)
      now - threshold
    end
  end
end
