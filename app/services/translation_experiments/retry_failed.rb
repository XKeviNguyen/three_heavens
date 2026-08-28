module TranslationExperiments
  class RetryFailed
    def self.call(experiment)
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
