module Finalizations
  class ReconcileRound
    def self.call(finalization_round)
      changed = false
      finalization_round.with_lock do
        runs = finalization_round.finalization_runs.lock.reload
        if runs.empty? || runs.any? { |run| !run.terminal? }
          unless finalization_round.running?
            finalization_round.update!(status: :running)
            changed = true
          end
        else
          status = runs.any?(&:failed?) ? :failed : :completed
          unless finalization_round.public_send("#{status}?")
            finalization_round.update!(status: status)
            changed = true
          end
        end
      end
      Pipelines::AdvancementScheduler.enqueue_for(finalization_round.final_translation.experiment) if changed
      finalization_round
    end
  end
end
