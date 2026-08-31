module TranslationExperiments
  class Start
    class Error < StandardError; end
    class InactiveModelError < Error; end
    class UnsupportedGatewayError < Error; end
    class InvalidExperimentStateError < Error; end
    class ContextBudgetError < Error; end

    def self.call(experiment:, llm_models:, capability_snapshots: {})
      new(experiment: experiment, llm_models: llm_models, capability_snapshots: capability_snapshots).call
    end

    def initialize(experiment:, llm_models:, capability_snapshots: {})
      @experiment = experiment
      @llm_models = llm_models
      @capability_snapshots = capability_snapshots
    end

    def call
      validate_request!
      plan = LongDocuments::Planner.call(experiment)
      budgets = preflight_budgets(plan)

      runs, schedules = create_runs(plan, budgets)
      Ai::RunScheduler.enqueue_all(schedules)
      runs
    rescue Ai::ContextBudget::Error, LongDocuments::Planner::SourceChangedError => error
      raise ContextBudgetError, error.message
    end

    private

    attr_reader :capability_snapshots, :experiment, :llm_models

    def validate_request!
      raise ActiveRecord::RecordNotSaved, "Experiment must be persisted" unless experiment.persisted?
      raise ActiveRecord::RecordInvalid, experiment unless experiment.valid?
      unless llm_models.is_a?(Array) && llm_models.any?
        raise ArgumentError, "Select at least one language model"
      end
      if llm_models.length > Ai::UsageLimits::MAX_TRANSLATION_MODELS
        raise ArgumentError, "Select no more than #{Ai::UsageLimits::MAX_TRANSLATION_MODELS} translation models"
      end
      if llm_models.uniq.length != llm_models.length
        raise ArgumentError, "Translation models cannot contain duplicates"
      end

      llm_models.each do |llm_model|
        unless llm_model.persisted? && llm_model.active?
          raise InactiveModelError, "Language model must be persisted and active"
        end

        next if llm_model.gateway == "openrouter"

        raise UnsupportedGatewayError,
              "Unsupported AI gateway: #{llm_model.gateway}"
      end
    end

    def preflight_budgets(plan)
      sources = plan ? plan.segments.to_a : [ experiment.document ]
      llm_models.to_h do |model|
        per_source = sources.to_h do |source|
          source_text = source.respond_to?(:source_text) ? source.source_text : experiment.document.source_text
          prompt = TranslationSegments::Prompt.build(experiment: experiment, source_text: source_text)
          budget = Ai::ContextBudget.call(
            model: model,
            system_prompt: prompt.fetch(:system_prompt),
            user_prompt: prompt.fetch(:user_prompt),
            stage: :translation,
            source_character_count: experiment.document.source_text.length,
            capability_snapshot: capability_snapshots[model.id]
          )
          [ source.id, budget ]
        end
        [ model.id, per_source ]
      end
    end

    def create_runs(plan, budgets)
      runs = []
      schedules = []

      Experiment.transaction do
        experiment.lock!
        if experiment.completed? || experiment.failed?
          raise InvalidExperimentStateError,
                "Cannot start a #{experiment.status} experiment"
        end

        llm_models.each do |llm_model|
          run = experiment.translation_runs.find_or_create_by!(llm_model: llm_model)
          runs << run
          if run.previously_new_record?
            if plan
              run.update!(status: :running, started_at: Time.current)
              plan.segments.each do |segment|
                segment_run = run.translation_segment_runs.create!(
                  experiment_segment: segment,
                  **budgets.fetch(llm_model.id).fetch(segment.id).snapshot_attributes
                )
                schedules << Ai::RunScheduler.prepare(run: segment_run, job_class: TranslationSegmentRunJob)
              end
            else
              run.assign_attributes(**budgets.fetch(llm_model.id).fetch(experiment.document.id).snapshot_attributes)
              schedules << Ai::RunScheduler.prepare(run: run, job_class: TranslationRunJob)
            end
          end
        end

        experiment.running! if experiment.pending?
      end

      [ runs, schedules ]
    end
  end
end
