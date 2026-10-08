module OpenRouter
  # Resolves a browser-submitted OpenRouter model identifier against the trusted
  # normalized catalog without writing to the database.
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

    def self.materialize!(model, activate: false)
      LlmModel.transaction(requires_new: true) do
        existing = LlmModel.lock.find_by(gateway: "openrouter", model_identifier: model.model_identifier)
        if existing
          raise InactiveModelError if !existing.active? && !activate

          existing.update!(active: true) if activate && !existing.active?
          existing
        else
          model.save!
          model
        end
      end
    rescue ActiveRecord::RecordNotUnique
      materialize!(LlmModel.find_by!(gateway: "openrouter", model_identifier: model.model_identifier), activate:)
    rescue ActiveRecord::RecordInvalid => error
      if error.record.errors.details == { model_identifier: [ { error: :taken, value: model.model_identifier } ] }
        return materialize!(LlmModel.find_by!(gateway: "openrouter", model_identifier: model.model_identifier), activate:)
      end
      raise Error, error.message
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
      return existing if existing

      LlmModel.new(
        active: true,
        gateway: "openrouter",
        provider: model.provider,
        model_identifier: model.identifier,
        display_name: model.name,
        context_window_tokens: context_tokens(model),
        max_output_tokens: output_tokens(model)
      )
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
