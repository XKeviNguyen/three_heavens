module Finalizations
  class RetryFailed
    def self.call(finalization_round)
      Ai::RetryFailedRuns.call(
        parent: finalization_round,
        runs_association: :finalization_runs,
        model_association: :finalizer_llm_model,
        job_class: FinalizationRunJob,
        prepare_parent: method(:prepare_parent!),
        lock_before: finalization_round.final_translation
      )
    end

    def self.prepare_parent!(round, _runs)
      final_translation = round.final_translation
      unless final_translation.draft? &&
             final_translation.current_version_id == round.base_final_translation_version_id
        raise FinalTranslations::StaleVersionError,
              "This refinement round targets an older draft and cannot be retried."
      end

      round.update!(status: :running)
    end
    private_class_method :prepare_parent!
  end
end
