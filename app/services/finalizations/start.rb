require "digest"

module Finalizations
  class Start
    def self.call(final_translation:, finalizer_ids:, capability_snapshots: {})
      new(
        final_translation: final_translation,
        finalizer_ids: finalizer_ids,
        capability_snapshots: capability_snapshots
      ).call
    end

    def initialize(final_translation:, finalizer_ids:, job_class: FinalizationRunJob, capability_snapshots: {})
      @final_translation = final_translation
      @finalizer_ids = finalizer_ids
      @job_class = job_class
      @capability_snapshots = capability_snapshots
    end

    def call
      raise ActiveRecord::RecordNotSaved, "Final translation must be persisted" unless final_translation.persisted?
      submitted_ids = normalized_ids!
      plan = LongDocuments::Planner.call(final_translation.experiment, create: false)

      round, schedules = FinalizationRound.transaction do
        final_translation.lock!
        finalizers = resolve_finalizers!(submitted_ids)
        key = selection_key(finalizers)
        raise FinalTranslations::InvalidStateError, "Reopen the final translation before requesting refinement" unless final_translation.draft?
        raise FinalTranslations::InvalidStateError, "Final translation has no current version" unless final_translation.current_version
        validate_segment_alignment!(plan) if plan

        active = final_translation.finalization_rounds.running.includes(:finalization_runs).first
        if active && active.base_version == final_translation.current_version && active.selection_key == key
          [ active, [] ]
        elsif active
          raise FinalTranslations::ActiveRoundError,
                "Another refinement round is still active for this final translation"
        else
          create_round!(finalizers, key, plan)
        end
      end
      Ai::RunScheduler.enqueue_all(schedules)
      round
    rescue Ai::ContextBudget::Error => error
      raise FinalTranslations::InvalidStateError,
            TranslationReferences::ContextBudgetMessage.for(
              experiment: final_translation.experiment,
              error: error
            )
    rescue LongDocuments::Planner::SourceChangedError => error
      raise FinalTranslations::InvalidStateError, error.message
    end

    private

    attr_reader :capability_snapshots, :final_translation, :finalizer_ids, :job_class

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

    def create_round!(finalizers, key, plan)
      round = final_translation.finalization_rounds.create!(
        base_version: final_translation.current_version,
        selection_key: key,
        status: :running
      )
      schedules = []
      finalizers.each do |finalizer|
        run = round.finalization_runs.create!(finalizer_llm_model: finalizer)
        if plan
          run.update!(status: :running, started_at: Time.current)
          plan.segments.each do |segment|
            prompt = Finalizations::Prompt.build(run, experiment_segment: segment)
            budget = Ai::ContextBudget.call(
              model: finalizer,
              **prompt,
              stage: :finalization,
              source_character_count: final_translation.experiment.document.source_text.length,
              capability_snapshot: capability_snapshots[finalizer.id]
            )
            segment_run = run.finalization_segment_runs.create!(
              experiment_segment: segment,
              **budget.snapshot_attributes
            )
            schedules << Ai::RunScheduler.prepare(run: segment_run, job_class: FinalizationSegmentRunJob)
          end
        else
          prompt = Finalizations::Prompt.build(run)
          budget = Ai::ContextBudget.call(
            model: finalizer,
            **prompt,
            stage: :finalization,
            source_character_count: final_translation.experiment.document.source_text.length,
            capability_snapshot: capability_snapshots[finalizer.id]
          )
          run.assign_attributes(**budget.snapshot_attributes)
          schedules << Ai::RunScheduler.prepare(run: run, job_class: job_class)
        end
      end
      [ round, schedules ]
    end

    def validate_segment_alignment!(plan)
      version = final_translation.current_version
      segment_ids = version.segments.pluck(:experiment_segment_id).sort
      unless version.segment_alignment_valid? && segment_ids == plan.segment_ids.sort
        raise FinalTranslations::InvalidStateError,
              "Segmented refinement is unavailable after an unaligned manual edit"
      end
    end
  end
end
