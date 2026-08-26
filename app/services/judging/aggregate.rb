module Judging
  class Aggregate
    EXPLANATION = "Candidates are ordered by total Borda points (N - rank + 1), then mean overall score, then TranslationRun ID ascending as a stable final tie-break.".freeze

    Result = Data.define(:winner_translation_run_id, :rankings, :explanation)

    def self.call(judge_round)
      evaluations = judge_round.judge_runs.completed.includes(:judge_evaluations)
        .flat_map(&:judge_evaluations)
      grouped = evaluations.group_by(&:translation_run_id)
      candidate_count = grouped.size

      rankings = grouped.map do |translation_run_id, candidate_evaluations|
        {
          "translation_run_id" => translation_run_id,
          "borda_points" => candidate_evaluations.sum do |evaluation|
            candidate_count - evaluation.rank + 1
          end,
          "mean_overall_score" => (
            candidate_evaluations.sum(&:overall_score).fdiv(candidate_evaluations.size).round(4)
          ),
          "judge_count" => candidate_evaluations.size
        }
      end
      rankings.sort_by! do |ranking|
        [
          -ranking.fetch("borda_points"),
          -ranking.fetch("mean_overall_score"),
          ranking.fetch("translation_run_id")
        ]
      end
      rankings.each_with_index { |ranking, index| ranking["aggregate_rank"] = index + 1 }

      Result.new(
        winner_translation_run_id: rankings.first.fetch("translation_run_id"),
        rankings: rankings,
        explanation: EXPLANATION
      )
    end
  end
end
