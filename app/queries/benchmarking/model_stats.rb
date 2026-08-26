module Benchmarking
  ModelStats = Data.define(
    :model,
    :completed_translation_count,
    :reviewed_candidate_count,
    :judged_candidate_count,
    :completed_judged_experiment_count,
    :official_wins,
    :review_average_score,
    :review_score_sample_count,
    :judge_average_score,
    :judge_score_sample_count,
    :total_translation_cost,
    :average_translation_cost,
    :cost_sample_count,
    :average_latency_seconds,
    :latency_sample_count,
    :average_total_tokens,
    :token_sample_count,
    :average_cost_per_judge_score_point,
    :cost_quality_sample_count,
    :reviewer_diagnostics,
    :judge_diagnostics
  ) do
    def official_win_rate
      return if completed_judged_experiment_count.zero?

      BigDecimal(official_wins.to_s) / completed_judged_experiment_count
    end
  end
end
