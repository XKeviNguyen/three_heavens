module Finalizations
  class ReconcileRound
    def self.call(finalization_round)
      finalization_round.with_lock do
        runs = finalization_round.finalization_runs.lock.reload
        if runs.empty? || runs.any? { |run| !run.terminal? }
          finalization_round.update!(status: :running) unless finalization_round.running?
          return finalization_round
        end

        status = runs.any?(&:failed?) ? :failed : :completed
        finalization_round.update!(status: status) unless finalization_round.public_send("#{status}?")
      end
      finalization_round
    end
  end
end
