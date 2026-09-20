class OpenRouterCatalogController < ApplicationController
  MAX_RESULTS = 50
  MAX_QUERY_LENGTH = 100
  ROLES = WorkflowProfileModelSelection::ROLES.freeze

  def index
    role = normalized_role
    query = normalized_query

    begin
      catalog = OpenRouter::Catalog.call
      models = catalog.models.select { |model| model.roles.include?(role) }
      models = filter(models, query).first(MAX_RESULTS)
      render json: {
        source: "live",
        role: role,
        fetched_at: catalog.fetched_at.iso8601,
        models: models.map { |model| serialize_catalog_model(model, role) }
      }
    rescue OpenRouter::Catalog::Error
      render json: {
        source: "fallback",
        role: role,
        message: "Live OpenRouter catalog is unavailable. Showing saved active models.",
        models: fallback_models(role, query).map { |model| serialize_llm_model(model, role) }
      }
    end
  end

  private

  def normalized_role
    value = params[:role].to_s
    ROLES.include?(value) ? value : "translator"
  end

  def normalized_query
    params[:q].to_s.strip.first(MAX_QUERY_LENGTH)
  end

  def filter(models, query)
    return models.sort_by(&:name) if query.blank?

    needle = query.downcase
    models.select do |model|
      [ model.name, model.identifier, model.provider ].any? { |value| value.downcase.include?(needle) }
    end.sort_by(&:name)
  end

  def fallback_models(role, query)
    return [] unless role == "translator"

    scope = LlmModel.active_openrouter.order(:display_name, :id).limit(MAX_RESULTS)
    return scope.to_a if query.blank?

    needle = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
    scope.where(
      "LOWER(display_name) LIKE :needle OR LOWER(model_identifier) LIKE :needle OR LOWER(provider) LIKE :needle",
      needle:
    ).to_a
  end

  def serialize_catalog_model(model, role)
    {
      identifier: model.identifier,
      name: model.name,
      provider: model.provider,
      context_length: model.context_length,
      max_completion_tokens: model.max_completion_tokens,
      prompt_price: price(model.prompt_price),
      completion_price: price(model.completion_price),
      free: model.free?,
      roles: model.roles,
      compatible: true,
      source: "live"
    }
  end

  def serialize_llm_model(model, role)
    compatible = role == "translator" && model.context_window_tokens.present? && model.max_output_tokens.present?
    {
      identifier: model.model_identifier,
      name: model.display_name,
      provider: model.provider,
      context_length: model.context_window_tokens,
      max_completion_tokens: model.max_output_tokens,
      prompt_price: nil,
      completion_price: nil,
      free: false,
      roles: compatible ? [ "translator" ] : [],
      compatible: compatible,
      source: "fallback"
    }
  end

  def price(value)
    return if value.nil?

    value.to_s("F")
  end
end
