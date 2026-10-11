module TranslationExperiments
  class RetryFailed
    # An explicit retry is new paid work: it runs under the owner's current
    # payment selection unless a caller passes an earlier authorization.
    def self.call(experiment, billing: nil)
      billing ||= Ai::BillingPolicy.authorize!(experiment.document.project.user)
      if experiment.translation_runs.failed.any?(&:segmented?)
        return Ai::RetryFailedSegmentRuns.call(
          parent: experiment,
          logical_runs_association: :translation_runs,
          child_runs_association: :translation_segment_runs,
          model_association: :llm_model,
          job_class: TranslationSegmentRunJob,
          billing: billing,
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
        billing: billing,
        prepare_parent: ->(parent, _) { parent.update!(status: :running) }
      )
    end
  end
end
