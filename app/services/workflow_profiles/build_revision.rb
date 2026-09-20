module WorkflowProfiles
  class BuildRevision
    class Error < StandardError; end
    class InvalidSelectionError < Error; end

    ROLE_LIMITS = {
      "translator" => [ 2, Ai::UsageLimits::MAX_TRANSLATION_MODELS, "Translation models" ],
      "reviewer" => [ 1, Ai::UsageLimits::MAX_REVIEWERS, "Reviewers" ],
      "judge" => [ 1, Ai::UsageLimits::MAX_JUDGES, "Judges" ],
      "finalizer" => [ 0, Ai::UsageLimits::MAX_FINALIZERS, "Finalizers" ]
    }.freeze

    def self.call(workflow_profile:, version:, attributes:)
      new(workflow_profile:, version:, attributes:).call
    end

    def initialize(workflow_profile:, version:, attributes:)
      @workflow_profile = workflow_profile
      @version = version
      @attributes = attributes.to_h.stringify_keys
    end

    def call
      completion_mode = attributes.fetch("completion_mode", "")
      unless completion_mode.in?(WorkflowProfileRevision::COMPLETION_MODES)
        raise Error, "Select a supported completion mode"
      end

      revision = workflow_profile.revisions.build(
        version: version,
        name: attributes.fetch("name", ""),
        description: attributes["description"],
        completion_mode: completion_mode
      )

      ROLE_LIMITS.each_key do |role|
        models = resolve_models!(role, completion_mode)
        models.each_with_index do |model, index|
          revision.model_selections.build(
            llm_model: model,
            role: role,
            position: index + 1,
            gateway_snapshot: model.gateway,
            provider_snapshot: model.provider,
            model_identifier_snapshot: model.model_identifier,
            display_name_snapshot: model.display_name
          )
        end
      end
      revision
    end

    private

    attr_reader :attributes, :version, :workflow_profile

    def resolve_models!(role, completion_mode)
      minimum, maximum, label = ROLE_LIMITS.fetch(role)
      minimum = 1 if role == "finalizer" && completion_mode == "refinement_proposals"
      ids = normalize_ids!(attributes.fetch("#{role}_ids", []), minimum:, maximum:, label:)
      models_by_id = LlmModel.where(id: ids).index_by(&:id)
      models = ids.map { |id| models_by_id[id] }
      unless models.all? { |model| model&.active? && model.gateway == "openrouter" }
        raise InvalidSelectionError, "Every #{role} must be an active OpenRouter model"
      end

      models
    end

    def normalize_ids!(value, minimum:, maximum:, label:)
      unless value.is_a?(Array) && value.all? { |id| id.is_a?(String) || id.is_a?(Integer) }
        raise InvalidSelectionError, "#{label} must be submitted as a list"
      end
      submitted = value.map(&:to_s).reject(&:blank?)
      if submitted.length < minimum
        raise InvalidSelectionError, "Select at least #{minimum} #{label.downcase}"
      end
      if submitted.length > maximum
        raise InvalidSelectionError, "Select no more than #{maximum} #{label.downcase}"
      end
      unless submitted.all? { |id| id.match?(/\A[1-9]\d*\z/) }
        raise InvalidSelectionError, "#{label} contain an invalid model selection"
      end
      if submitted.uniq.length != submitted.length
        raise InvalidSelectionError, "#{label} cannot contain duplicate models"
      end

      submitted.map(&:to_i).sort
    end
  end
end
