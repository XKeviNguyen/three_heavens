class OpenRouterCatalogController < ApplicationController
  MAX_RESULTS = 50
  MAX_QUERY_LENGTH = 100
  MAX_PROVIDERS = 200
  ROLES = WorkflowProfileModelSelection::ROLES.freeze
  SORTS = %w[name price context].freeze

  def index
    role = normalized_role
    query = normalized_query
    provider = normalized_provider
    free_only = params[:free].to_s == "true"
    sort = normalized_sort

    begin
      catalog = OpenRouter::Catalog.call
      compatible = catalog.models.select { |model| model.roles.include?(role) }
      render json: serialize_live(compatible, role:, query:, provider:, free_only:, fetched_at: catalog.fetched_at)
    rescue OpenRouter::Catalog::Error
      render json: serialize_fallback(fallback_models(role), role:, query:, provider:, free_only:)
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

  def normalized_provider
    params[:provider].to_s.strip.first(100)
  end

  def normalized_sort
    value = params[:sort].to_s
    SORTS.include?(value) ? value : "name"
  end

  def filter(models, query:, provider:, free_only:)
    result = models
    result = result.select { |model| model.provider == provider } if provider.present?
    result = result.select(&:free?) if free_only
    if query.present?
      needle = query.downcase
      result = result.select do |model|
        [ model.name, model.identifier, model.provider ].any? { |value| value.downcase.include?(needle) }
      end
    end
    sort_models(result)
  end

  def sort_models(models)
    case normalized_sort
    when "price"
      models.sort_by { |model| [ model.prompt_price.nil? ? Float::INFINITY : model.prompt_price, model.name.downcase ] }
    when "context"
      models.sort_by { |model| [ -(model.context_length || 0), model.name.downcase ] }
    else
      models.sort_by { |model| model.name.downcase }
    end
  end

  def serialize_live(models, role:, query:, provider:, free_only:, fetched_at:)
    filtered = filter(models, query:, provider:, free_only:)
    {
      source: "live",
      role: role,
      providers: provider_names(models),
      fetched_at: fetched_at.iso8601,
      total: filtered.size,
      filters: { provider: provider, free: free_only, sort: normalized_sort },
      models: filtered.first(MAX_RESULTS).map { |model| serialize_catalog_model(model, role) }
    }
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
      translator: model.translation_capable?,
      structured: model.structured_capable?,
      roles: model.roles,
      compatible: model.roles.include?(role),
      source: "live"
    }
  end

  def fallback_models(role)
    return [] unless role == "translator"

    LlmModel.active_openrouter.order(:display_name, :id).limit(MAX_RESULTS).to_a
  end

  def serialize_fallback(models, role:, query:, provider:, free_only:)
    serialized = models.map do |model|
      {
        identifier: model.model_identifier,
        name: model.display_name,
        provider: model.provider,
        context_length: model.context_window_tokens,
        max_completion_tokens: model.max_output_tokens,
        prompt_price: nil,
        completion_price: nil,
        free: false,
        translator: true,
        structured: false,
        roles: [ "translator" ],
        compatible: role == "translator",
        source: "fallback"
      }
    end
    filtered = serialized.select do |model|
      (provider.blank? || model[:provider] == provider) &&
        (!free_only || model[:free]) &&
        (query.blank? || [ model[:name], model[:identifier], model[:provider] ].any? { |value| value.downcase.include?(query.downcase) })
    end
    {
      source: "fallback",
      role: role,
      message: "Live OpenRouter catalog is unavailable. Showing saved active models.",
      providers: filtered.map { |model| model[:provider] }.uniq.sort.first(MAX_PROVIDERS),
      models: filtered.first(MAX_RESULTS)
    }
  end

  def provider_names(models)
    models.map(&:provider).uniq.sort.first(MAX_PROVIDERS)
  end

  def price(value)
    return if value.nil?

    value.to_s("F")
  end
end
