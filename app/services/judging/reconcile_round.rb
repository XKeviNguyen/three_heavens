module Judging
  class ReconcileRound
    def self.call(judge_round)
      judge_round.with_lock do
        judge_runs = judge_round.judge_runs.reload
        if judge_runs.empty? || judge_runs.any? { |run| !run.terminal? }
          judge_round.update!(status: :running) unless judge_round.running?
        elsif judge_runs.any?(&:failed?)
          judge_round.update!(
            status: :failed,
            winner_translation_run: nil,
            aggregate_rankings: [],
            aggregation_explanation: nil
          )
        else
          aggregate = Judging::Aggregate.call(judge_round)
          judge_round.update!(
            status: :completed,
            winner_translation_run_id: aggregate.winner_translation_run_id,
            aggregate_rankings: aggregate.rankings,
            aggregation_explanation: aggregate.explanation
          )
        end
      end

      judge_round
    end
  end
end
