module TranslationExperiments
  class Start
    class Error < StandardError; end
    class InactiveModelError < Error; end
    class UnsupportedGatewayError < Error; end
    class InvalidExperimentStateError < Error; end

    def self.call(experiment:, llm_models:)
      new(experiment: experiment, llm_models: llm_models).call
    end

    def initialize(experiment:, llm_models:)
      @experiment = experiment
      @llm_models = llm_models
    end

    def call
      validate_request!

      runs, created_runs = create_runs
      created_runs.each { |run| TranslationRunJob.perform_later(run.id) }
      runs
    end

    private

    attr_reader :experiment, :llm_models

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

    def create_runs
      runs = []
      created_runs = []

      Experiment.transaction do
        experiment.lock!
        if experiment.completed? || experiment.failed?
          raise InvalidExperimentStateError,
                "Cannot start a #{experiment.status} experiment"
        end

        llm_models.each do |llm_model|
          run = experiment.translation_runs.find_or_create_by!(llm_model: llm_model)
          runs << run
          created_runs << run if run.previously_new_record?
        end

        experiment.running! if experiment.pending?
      end

      [ runs, created_runs ]
    end
  end
end
