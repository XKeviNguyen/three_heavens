module TranslationExperiments
  class ReconcileExperiment
    def self.call(experiment)
      changed = false
      experiment.with_lock do
        runs = experiment.translation_runs.lock.reload
        status = if runs.empty? || runs.any? { |run| !run.terminal? }
          :running
        elsif runs.any?(&:failed?)
          :failed
        else
          :completed
        end
        unless experiment.public_send("#{status}?")
          experiment.update!(status: status)
          changed = true
        end
      end
      Pipelines::AdvancementScheduler.enqueue_for(experiment) if changed
      experiment
    end
  end
end
