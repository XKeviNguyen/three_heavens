module TranslationExperiments
  class RetryFailed
    def self.call(experiment)
      if experiment.translation_runs.failed.any?(&:segmented?)
        return Ai::RetryFailedSegmentRuns.call(
          parent: experiment,
          logical_runs_association: :translation_runs,
          child_runs_association: :translation_segment_runs,
          model_association: :llm_model,
          job_class: TranslationSegmentRunJob,
          prepare_parent: ->(parent, _) { parent.update!(status: :running) },
          prepare_logical: ->(run) { run.assign_attributes(translated_text: nil) },
          prepare_child: ->(run) { run.assign_attributes(translated_text: nil) }
        )
      end

      Ai::RetryFailedRuns.call(
        parent: experiment,
        runs_association: :translation_runs,
        model_association: :llm_model,
        job_class: TranslationRunJob,
        prepare_parent: ->(parent, _) { parent.update!(status: :running) }
      )
    end
  end
end
