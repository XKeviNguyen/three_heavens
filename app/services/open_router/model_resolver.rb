module OpenRouter
  # Resolves a browser-submitted OpenRouter model identifier against the trusted
  # normalized catalog and returns the canonical persisted LlmModel.
  #
  # Browser input is only ever a bounded identifier string. Provider, display
  # name, context window, and output capability are always taken from the
  # server-side catalog, never from request parameters.
  class ModelResolver
    class Error < StandardError; end
    class UnknownModelError < Error; end
    class IncompatibleModelError < Error; end
    class InactiveModelError < Error; end

    ROLE_ELIGIBILITY = {
      "translator" => :translation_capable?,
      "reviewer" => :structured_capable?,
      "judge" => :structured_capable?,
      "finalizer" => :structured_capable?
    }.freeze

    def self.call(identifier:, role: "translator", catalog: Catalog.new)
      new(identifier: identifier, role: role, catalog: catalog).call
    end

    def initialize(identifier:, role:, catalog:)
      @identifier = identifier.to_s
      @role = role.to_s
      @catalog = catalog
    end

    def call
      raise UnknownModelError unless identifier.match?(LlmModel::OPENROUTER_IDENTIFIER_FORMAT)

      model = catalog_models.find { |candidate| candidate.identifier == identifier }
      raise UnknownModelError unless model

      eligible = ROLE_ELIGIBILITY.fetch(@role) { ROLE_ELIGIBILITY.fetch("translator") }
      raise IncompatibleModelError unless model.public_send(eligible)

      existing = LlmModel.find_by(gateway: "openrouter", model_identifier: identifier)
      if existing
        raise InactiveModelError unless existing.active?

        return existing
      end

      LlmModel.create!(
        active: true,
        gateway: "openrouter",
        provider: model.provider,
        model_identifier: model.identifier,
        display_name: model.name,
        context_window_tokens: context_tokens(model),
        max_output_tokens: output_tokens(model)
      )
    rescue ActiveRecord::RecordInvalid => error
      raise Error, error.message
    rescue Catalog::Error
      raise Error
    end

    private

    attr_reader :catalog, :identifier, :role

    def catalog_models
      @catalog_models ||= catalog.call.models
    end

    def context_tokens(model)
      [ model.context_length, LlmModel::MAX_CONTEXT_WINDOW_TOKENS ].min
    end

    def output_tokens(model)
      requested = model.max_completion_tokens.to_i
      raise IncompatibleModelError if requested < Catalog::STAGE_OUTPUT_RESERVE

      [ requested, context_tokens(model) - 1, LlmModel::MAX_OUTPUT_TOKENS ].min
    end
  end
end
