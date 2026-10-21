module Settings
  # Account → AI settings: who pays for the owner's AI work. The page is a
  # React island over a server-rendered form, so it also works without
  # JavaScript; mutations answer JSON for the island and redirects for forms.
  class AiSettingsController < ApplicationController
    include AiSettingsResponses

    rate_limit to: MUTATION_LIMIT, within: MUTATION_WINDOW, by: -> { current_user.id }, name: "ai_settings",
               with: :render_rate_limited, only: :update

    class_attribute :key_status, instance_writer: false, default: OpenRouter::KeyStatus

    def show
      @ai_settings = Accounts::AiSettings.state(current_user)
      @key_status = personal_key_status
    end

    def update
      attributes = params.expect(ai_settings: %i[payment_source state_token])
      respond_with_settings(notice: t("ai_settings.flash.source_saved")) do
        Accounts::AiSettings.select_source!(
          current_user,
          source: attributes[:payment_source],
          state_token: attributes[:state_token]
        )
      end
    end

    private

    # What OpenRouter reports for the owner's saved key; nil without one, or
    # when it cannot be decrypted (the page already reports that state).
    def personal_key_status
      credential = current_user.open_router_credentials.active.first
      credential && key_status.cached(credential.api_key)
    rescue ActiveRecord::Encryption::Errors::Decryption
      nil
    end
  end
end
