require "digest"

module Finalizations
  class Start
    def self.call(final_translation:, finalizer_ids:)
      new(final_translation: final_translation, finalizer_ids: finalizer_ids).call
    end

    def initialize(final_translation:, finalizer_ids:, job_class: FinalizationRunJob)
      @final_translation = final_translation
      @finalizer_ids = finalizer_ids
      @job_class = job_class
    end

    def call
      raise ActiveRecord::RecordNotSaved, "Final translation must be persisted" unless final_translation.persisted?
      submitted_ids = normalized_ids!

      round, schedules = FinalizationRound.transaction do
        final_translation.lock!
        finalizers = resolve_finalizers!(submitted_ids)
        key = selection_key(finalizers)
        raise FinalTranslations::InvalidStateError, "Reopen the final translation before requesting refinement" unless final_translation.draft?
        raise FinalTranslations::InvalidStateError, "Final translation has no current version" unless final_translation.current_version

        active = final_translation.finalization_rounds.running.includes(:finalization_runs).first
        if active && active.base_version == final_translation.current_version && active.selection_key == key
          [ active, [] ]
        elsif active
          raise FinalTranslations::ActiveRoundError,
                "Another refinement round is still active for this final translation"
        else
          create_round!(finalizers, key)
        end
      end
      Ai::RunScheduler.enqueue_all(schedules)
      round
    end

    private

    attr_reader :final_translation, :finalizer_ids, :job_class

    def normalized_ids!
      Ai::UsageLimits.normalize_model_ids(
        finalizer_ids,
        maximum: Ai::UsageLimits::MAX_FINALIZERS,
        label: "Finalizers"
      )
    rescue Ai::UsageLimits::InvalidSelection => error
      raise FinalTranslations::InvalidSelectionError, error.message
    end

    def resolve_finalizers!(ids)
      finalizers = LlmModel.lock.where(id: ids).order(:id).to_a
      eligible = finalizers.map(&:id) == ids && finalizers.all? do |model|
        model.active? && model.gateway == "openrouter"
      end
      unless eligible
        raise FinalTranslations::InvalidSelectionError,
              "Every finalizer must be an active OpenRouter model"
      end

      finalizers
    end

    def selection_key(finalizers)
      Digest::SHA256.hexdigest(finalizers.map(&:id).join(","))
    end

    def create_round!(finalizers, key)
      round = final_translation.finalization_rounds.create!(
        base_version: final_translation.current_version,
        selection_key: key,
        status: :running
      )
      schedules = []
      finalizers.each do |finalizer|
        run = round.finalization_runs.create!(finalizer_llm_model: finalizer)
        schedules << Ai::RunScheduler.prepare(run: run, job_class: job_class)
      end
      [ round, schedules ]
    end
  end
end
