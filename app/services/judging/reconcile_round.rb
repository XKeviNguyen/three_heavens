module Judging
  class ReconcileRound
    def self.call(judge_round)
      changed = false
      judge_round.with_lock do
        judge_runs = judge_round.judge_runs.lock.reload
        if judge_runs.empty? || judge_runs.any? { |run| !run.terminal? }
          changed = update_if_changed(judge_round,
            status: :running,
            winner_translation_run: nil,
            aggregate_rankings: [],
            aggregation_explanation: nil
          )
        elsif judge_runs.any?(&:failed?)
          changed = update_if_changed(judge_round,
            status: :failed,
            winner_translation_run: nil,
            aggregate_rankings: [],
            aggregation_explanation: nil
          )
        else
          aggregate = Judging::Aggregate.call(judge_round)
          changed = update_if_changed(judge_round,
            status: :completed,
            winner_translation_run_id: aggregate.winner_translation_run_id,
            aggregate_rankings: aggregate.rankings,
            aggregation_explanation: aggregate.explanation
          )
        end
      end

      Pipelines::AdvancementScheduler.enqueue_for(judge_round.experiment) if changed
      judge_round
    end

    def self.update_if_changed(judge_round, attributes)
      judge_round.assign_attributes(attributes)
      return false unless judge_round.has_changes_to_save?

      judge_round.save!
      true
    end
    private_class_method :update_if_changed
  end
end
