module Ai
  module SegmentAggregation
    OMISSION_MARKER = "\n\n[Additional segment data omitted to preserve the stored field limit.]".freeze
    TOKEN_TELEMETRY_FIELDS = %i[
      prompt_tokens completion_tokens total_tokens cached_tokens reasoning_tokens
    ].freeze

    module_function

    def telemetry_attributes(segment_runs)
      attributes = TOKEN_TELEMETRY_FIELDS.to_h do |field|
        values = segment_runs.map { |run| run.public_send(field) }
        [ field, values.none?(&:nil?) ? values.sum : nil ]
      end
      costs = segment_runs.map(&:cost)
      known_costs = costs.compact
      attributes.merge(
        cost: known_costs.empty? ? nil : known_costs.sum,
        cost_complete: costs.none?(&:nil?),
        telemetry_complete: telemetry_complete?(segment_runs)
      )
    end

    def telemetry_complete?(runs)
      runs.all? do |run|
        TOKEN_TELEMETRY_FIELDS.none? { |field| run.public_send(field).nil? }
      end
    end

    def bounded_join(values, maximum:, separator: "\n\n")
      joined = values.filter_map(&:presence).join(separator)
      return joined if joined.length <= maximum

      joined.first(maximum - OMISSION_MARKER.length) + OMISSION_MARKER
    end

    def common_value(runs, attribute)
      values = runs.map { |run| run.public_send(attribute) }.uniq
      values.one? ? values.first : nil
    end
  end
end
