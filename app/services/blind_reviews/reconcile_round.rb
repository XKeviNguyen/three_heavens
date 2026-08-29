module BlindReviews
  class ReconcileRound
    def self.call(review_round)
      changed = false
      review_round.with_lock do
        review_runs = review_round.review_runs.lock.reload
        status = aggregate_status(review_runs)
        unless review_round.status == status.to_s
          review_round.update!(status: status)
          changed = true
        end
      end

      Pipelines::AdvancementScheduler.enqueue_for(review_round.experiment) if changed
      review_round
    end

    def self.aggregate_status(review_runs)
      return :running if review_runs.empty? || review_runs.any? { |run| !run.terminal? }
      return :failed if review_runs.any?(&:failed?)

      :completed
    end
    private_class_method :aggregate_status
  end
end
