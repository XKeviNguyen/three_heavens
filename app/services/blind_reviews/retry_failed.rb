module BlindReviews
  class RetryFailed
    REVIEW_OUTPUT_ATTRIBUTES = %i[
      faithfulness_score naturalness_score terminology_score
      instruction_adherence_score overall_score strengths issues
      recommended_corrections suggested_translation
    ].freeze

    # An explicit retry is new paid work: it runs under the owner's current
    # payment selection unless a caller passes an earlier authorization.
    def self.call(review_round, billing: nil)
      billing ||= Ai::BillingPolicy.authorize!(review_round.experiment.document.project.user)
      if review_round.review_runs.failed.any?(&:segmented?)
        return Ai::RetryFailedSegmentRuns.call(
          parent: review_round,
          logical_runs_association: :review_runs,
          child_runs_association: :review_segment_runs,
          model_association: :reviewer_llm_model,
          job_class: ReviewSegmentRunJob,
          billing: billing,
          prepare_parent: ->(parent, _) { parent.update!(status: :running) },
          prepare_logical: ->(run) { run.review_evaluations.update_all(REVIEW_OUTPUT_ATTRIBUTES.index_with(nil)) },
          prepare_child: ->(run) { run.assign_attributes(evaluations: []) }
        )
      end

      Ai::RetryFailedRuns.call(
        parent: review_round,
        runs_association: :review_runs,
        model_association: :reviewer_llm_model,
        job_class: ReviewRunJob,
        billing: billing,
        prepare_parent: ->(parent, _) { parent.update!(status: :running) },
        prepare_run: ->(run) { run.review_evaluations.update_all(REVIEW_OUTPUT_ATTRIBUTES.index_with(nil)) }
      )
    end
  end
end
