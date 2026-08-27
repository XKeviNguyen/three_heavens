module Finalizations
  class ApplyProposal
    def self.call(final_translation:, finalization_run_id:)
      new(
        final_translation: final_translation,
        finalization_run_id: finalization_run_id
      ).call
    end

    def initialize(final_translation:, finalization_run_id:)
      @final_translation = final_translation
      @finalization_run_id = finalization_run_id
    end

    def call
      FinalTranslation.transaction do
        final_translation.lock!
        run = scoped_run
        existing = final_translation.versions.find_by(source_finalization_run_id: run.id)
        return existing if existing

        validate_application!(run)
        version = final_translation.versions.create!(
          version_number: final_translation.versions.maximum(:version_number).to_i + 1,
          content: run.proposed_translation,
          origin: :ai_applied,
          source_finalization_run: run,
          change_note: "Applied refinement proposed by #{run.finalizer_llm_model.display_name}"
        )
        final_translation.update!(current_version: version)
        version
      end
    end

    private

    attr_reader :final_translation, :finalization_run_id

    def scoped_run
      FinalizationRun.joins(:finalization_round).where(
        finalization_rounds: { final_translation_id: final_translation.id }
      ).find(finalization_run_id)
    end

    def validate_application!(run)
      unless final_translation.draft?
        raise FinalTranslations::InvalidStateError, "Reopen the final translation before applying a proposal"
      end
      unless run.completed? && run.proposed_translation.present?
        raise FinalTranslations::InvalidProposalError, "Only a completed nonblank proposal can be applied"
      end
      unless final_translation.current_version_id == run.finalization_round.base_final_translation_version_id
        raise FinalTranslations::StaleVersionError,
              "This proposal is stale because the final draft has changed"
      end
    end
  end
end
