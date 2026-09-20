module Pipelines
  class ExecutionSummary
    Result = Data.define(
      :logical_status_counts,
      :physical_status_counts,
      :attempt_status_counts,
      :known_total_tokens,
      :token_sample_count,
      :known_cost,
      :cost_sample_count,
      :average_latency_seconds,
      :latency_sample_count,
      :tracked_physical_run_count,
      :recent_failures
    ) do
      def logical_total
        logical_status_counts.values.sum
      end

      def physical_total
        physical_status_counts.values.sum
      end

      def attempt_total
        attempt_status_counts.values.sum
      end

      def token_telemetry_incomplete?
        attempt_total.positive? && token_sample_count < attempt_total
      end

      def cost_telemetry_incomplete?
        attempt_total.positive? && cost_sample_count < attempt_total
      end

      def attempt_coverage_incomplete?
        tracked_physical_run_count < physical_total
      end
    end

    LOGICAL_SCOPES = {
      "TranslationRun" => ->(experiment_id) { TranslationRun.where(experiment_id: experiment_id) },
      "ReviewRun" => lambda { |experiment_id|
        ReviewRun.joins(:review_round).where(review_rounds: { experiment_id: experiment_id })
      },
      "JudgeRun" => lambda { |experiment_id|
        JudgeRun.joins(judge_round: :review_round).where(review_rounds: { experiment_id: experiment_id })
      },
      "FinalizationRun" => lambda { |experiment_id|
        FinalizationRun.joins(finalization_round: :final_translation)
          .where(final_translations: { experiment_id: experiment_id })
      }
    }.freeze

    CHILD_TYPES = {
      "TranslationRun" => [ "TranslationSegmentRun", TranslationSegmentRun, :translation_run_id ],
      "ReviewRun" => [ "ReviewSegmentRun", ReviewSegmentRun, :review_run_id ],
      "JudgeRun" => [ "JudgeSegmentRun", JudgeSegmentRun, :judge_run_id ],
      "FinalizationRun" => [ "FinalizationSegmentRun", FinalizationSegmentRun, :finalization_run_id ]
    }.freeze

    def self.call(experiment:)
      new(experiment).call
    end

    def initialize(experiment)
      @experiment = experiment
    end

    def call
      logical = logical_scopes
      physical = physical_scopes(logical)
      attempts = attempt_scope(physical)
      aggregate = attempts.pick(
        Arel.sql("SUM(total_tokens)"),
        Arel.sql("COUNT(total_tokens)"),
        Arel.sql("SUM(cost)"),
        Arel.sql("COUNT(cost)"),
        Arel.sql("AVG(EXTRACT(EPOCH FROM (completed_at - started_at))) FILTER (WHERE completed_at IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE completed_at IS NOT NULL)"),
        Arel.sql("COUNT(DISTINCT (provider_run_type, provider_run_id))")
      )

      Result.new(
        logical_status_counts: combined_status_counts(logical.values),
        physical_status_counts: combined_status_counts(physical.values.map(&:last)),
        attempt_status_counts: attempts.group(:status).count,
        known_total_tokens: aggregate[1].positive? ? aggregate[0].to_i : nil,
        token_sample_count: aggregate[1],
        known_cost: aggregate[3].positive? ? BigDecimal(aggregate[2].to_s) : nil,
        cost_sample_count: aggregate[3],
        average_latency_seconds: aggregate[4] && BigDecimal(aggregate[4].to_s),
        latency_sample_count: aggregate[5],
        tracked_physical_run_count: aggregate[6],
        recent_failures: attempts.failed.order(completed_at: :desc, id: :desc).limit(20).to_a
      )
    end

    private

    attr_reader :experiment

    def logical_scopes
      LOGICAL_SCOPES.transform_values { |builder| builder.call(experiment.id) }
    end

    def physical_scopes(logical)
      logical.each_with_object({}) do |(logical_type, scope), result|
        ids = scope.select(:id)
        child_type, child_class, foreign_key = CHILD_TYPES.fetch(logical_type)
        children = child_class.where(foreign_key => ids)
        result[logical_type] = if children.exists?
          [ child_type, children ]
        else
          [ logical_type, scope ]
        end
      end
    end

    def attempt_scope(physical)
      physical.values.reduce(AiProviderAttempt.none) do |scope, (type, records)|
        scope.or(AiProviderAttempt.where(provider_run_type: type, provider_run_id: records.select(:id)))
      end
    end

    def combined_status_counts(scopes)
      scopes.each_with_object(Hash.new(0)) do |scope, counts|
        scope.group(:status).count.each { |status, count| counts[status] += count }
      end
    end
  end
end
