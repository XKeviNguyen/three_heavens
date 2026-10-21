# Models chosen for a role in a model browser (shared/_model_browser) arrive as
# OpenRouter identifiers. Each is resolved against the server-side catalog,
# which also checks that the model can do the role (reviewers, judges and
# refiners need structured output), and saved as an LlmModel, the same way
# the translation workspace and workflow profiles do. Nothing about a model is
# taken from the request beyond its identifier.
module CatalogModelSelection
  extend ActiveSupport::Concern

  class Error < StandardError; end

  private

  # identifiers: browser picks; saved_ids: models resolved earlier and shown
  # again (an LlmModel id each). Returns LlmModel ids, saved first.
  def resolved_model_ids(identifiers:, saved_ids:, role:, maximum:)
    picks = Array(identifiers).map(&:to_s).reject(&:blank?)
    saved = Array(saved_ids).map(&:to_s).reject(&:blank?)
    raise Error, t("model_selection.too_many", count: maximum) if picks.size + saved.size > maximum
    raise Error, t("model_selection.duplicate") if picks.uniq.size != picks.size

    reject_incapable_saved!(saved, role:)
    saved + picks.map { |identifier| resolve_catalog_model(identifier, role:).id.to_s }
  end

  # A saved model the catalog says cannot do the role is refused. When the
  # catalog cannot answer (outage, model retired) the model is let through:
  # the run then fails with its own explanation instead of blocking the page.
  def reject_incapable_saved!(saved_ids, role:)
    LlmModel.where(id: saved_ids).find_each do |model|
      OpenRouter::ModelResolver.call(identifier: model.model_identifier, role: role)
    rescue OpenRouter::ModelResolver::IncompatibleModelError
      raise Error, t("model_selection.incompatible", role: t("model_selection.roles.#{role}"))
    rescue OpenRouter::ModelResolver::Error
      next
    end
  end

  # The one model picked to replace a failed run: a catalog identifier, or a
  # saved model when the browser fell back to saved models (catalog outage).
  def replacement_model(role:)
    picked = params[:replacement]
    picked = ActionController::Parameters.new unless picked.is_a?(ActionController::Parameters)
    identifiers = Array(picked[:identifiers]).map(&:to_s).reject(&:blank?)
    saved_ids = Array(picked[:ids]).map(&:to_s).reject(&:blank?)
    raise Error, t("model_selection.choose_one") unless identifiers.size + saved_ids.size == 1

    LlmModel.find(resolved_model_ids(identifiers:, saved_ids:, role:, maximum: 1).sole)
  end

  def scalar_param(key)
    value = params[key]
    raise ActionController::BadRequest, "#{key} must be a single value" unless value.is_a?(String)

    value
  end

  def resolve_catalog_model(identifier, role:)
    OpenRouter::ModelResolver.materialize!(OpenRouter::ModelResolver.call(identifier: identifier.to_s, role: role))
  rescue OpenRouter::ModelResolver::IncompatibleModelError
    raise Error, t("model_selection.incompatible", role: t("model_selection.roles.#{role}"))
  rescue OpenRouter::ModelResolver::Error
    raise Error, t("model_selection.unavailable")
  end
end
