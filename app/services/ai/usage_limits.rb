module Ai
  module UsageLimits
    MAX_SOURCE_CHARACTERS = 100_000
    MAX_INSTRUCTION_CHARACTERS = 10_000
    MAX_TRANSLATION_MODELS = 6
    MAX_REVIEWERS = 5
    MAX_JUDGES = 5
    MAX_FINALIZERS = 5

    class InvalidSelection < StandardError; end

    def self.normalize_model_ids(value, maximum:, label:)
      unless value.is_a?(Array)
        raise InvalidSelection, "#{label} must be submitted as a list"
      end

      submitted = value.map(&:to_s)
      if submitted.empty? || submitted.any?(&:blank?)
        raise InvalidSelection, "Select at least one valid #{label.downcase}"
      end
      if submitted.length > maximum
        raise InvalidSelection, "Select no more than #{maximum} #{label.downcase}"
      end
      unless submitted.all? { |id| id.match?(/\A[1-9]\d*\z/) }
        raise InvalidSelection, "#{label} contain an invalid model selection"
      end
      if submitted.uniq.length != submitted.length
        raise InvalidSelection, "#{label} cannot contain duplicate models"
      end

      submitted.map(&:to_i).sort
    end
  end
end
