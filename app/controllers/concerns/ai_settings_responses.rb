# Shared responses for the AI settings mutations. JSON callers (the settings
# island) get the current state, never the key; form posts get a redirect.
module AiSettingsResponses
  extend ActiveSupport::Concern

  MUTATION_LIMIT = 10
  MUTATION_WINDOW = 1.minute

  included do
    before_action { response.headers["Cache-Control"] = "no-store" }
  end

  private

  def respond_with_settings(notice:)
    state = yield
    respond_to do |format|
      format.json { render json: { state: state, notice: notice } }
      format.html { redirect_to settings_ai_settings_path, notice: notice, status: :see_other }
    end
  rescue Accounts::AiSettings::StaleError
    render_settings_error(I18n.t("ai_settings.errors.stale"), status: :conflict)
  rescue Accounts::AiSettings::InvalidError => error
    render_settings_error(error.message, status: :unprocessable_content, field: error.field)
  end

  def render_settings_error(message, status:, field: nil)
    respond_to do |format|
      format.json do
        render json: { error: message, field: field, state: Accounts::AiSettings.state(current_user) }, status: status
      end
      format.html { redirect_to settings_ai_settings_path, alert: message, status: :see_other }
    end
  end

  def render_rate_limited
    render_settings_error(I18n.t("ai_settings.errors.rate_limited"), status: :too_many_requests)
  end
end
