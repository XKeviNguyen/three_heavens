module TranslationExperiments
  class ReconcileExperiment
    def self.call(experiment)
      experiment.with_lock do
        runs = experiment.translation_runs.lock.reload
        status = if runs.empty? || runs.any? { |run| !run.terminal? }
          :running
        elsif runs.any?(&:failed?)
          :failed
        else
          :completed
        end
        experiment.update!(status: status) unless experiment.public_send("#{status}?")
      end
      experiment
    end
  end
end
