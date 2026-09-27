module Settings
  class ModelsController < ApplicationController
    ALLOWED_MODEL_ATTRIBUTES = %w[
      provider model_identifier display_name context_window_tokens max_output_tokens
    ].freeze

    before_action :require_admin
    before_action :set_llm_model, only: %i[edit update activate deactivate]

    def index
      @llm_models = openrouter_models.order(:display_name, :id).to_a
      @usage_by_model_id = ModelCatalog::UsageSummary.call(
        model_ids: @llm_models.map(&:id)
      )
    end

    def new
      @llm_model = openrouter_models.new(active: true)
    end

    def create
      @llm_model = openrouter_models.new(model_params.merge(active: true))

      if @llm_model.save
        redirect_to settings_models_path, notice: t("flash_ui.model.added")
      else
        render :new, status: :unprocessable_content
      end
    end

    def create_from_catalog
      identifier = params.require(:model_identifier)
      unless identifier.is_a?(String) && identifier.match?(LlmModel::OPENROUTER_IDENTIFIER_FORMAT)
        raise ActionController::BadRequest, "model_identifier is invalid"
      end

      resolved = OpenRouter::ModelResolver.call(identifier: identifier, role: "translator")
      was_inactive = resolved.persisted? && !resolved.active?
      was_new = !resolved.persisted?
      model = OpenRouter::ModelResolver.materialize!(resolved, activate: true)
      action = was_inactive ? "activated" : (was_new ? "added and activated" : "already active")
      redirect_to settings_models_path, notice: t("flash_ui.model.catalog_action", name: model.display_name, action: t("flash_ui.model.actions.#{action.parameterize(separator: "_")}"))
    rescue OpenRouter::ModelResolver::Error, OpenRouter::Catalog::Error
      redirect_to settings_models_path, alert: t("flash_ui.model.catalog_failed")
    end

    def edit
    end

    def update
      if @llm_model.update(model_params)
        redirect_to settings_models_path, notice: t("flash_ui.model.updated")
      else
        render :edit, status: :unprocessable_content
      end
    end

    def activate
      @llm_model.update!(active: true)
      redirect_to settings_models_path, notice: t("flash_ui.model.activated", name: @llm_model.display_name)
    end

    def deactivate
      @llm_model.update!(active: false)
      redirect_to settings_models_path, notice: t("flash_ui.model.deactivated", name: @llm_model.display_name)
    end

    private

    def openrouter_models
      LlmModel.where(gateway: "openrouter")
    end

    def set_llm_model
      @llm_model = openrouter_models.find(params[:id])
    end

    def model_params
      submitted = params.require(:llm_model)
      unless submitted.is_a?(ActionController::Parameters)
        raise ActionController::BadRequest, "llm_model must be a parameter object"
      end

      unexpected_attributes = submitted.keys - ALLOWED_MODEL_ATTRIBUTES
      if unexpected_attributes.any?
        raise ActionController::BadRequest, "Unsupported model attributes"
      end

      submitted.permit(*ALLOWED_MODEL_ATTRIBUTES)
    end
  end
end
