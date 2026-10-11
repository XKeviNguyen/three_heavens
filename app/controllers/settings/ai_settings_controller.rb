module Settings
  # Account → AI settings: who pays for the owner's AI work. The page is a
  # React island over a server-rendered form, so it also works without
  # JavaScript; mutations answer JSON for the island and redirects for forms.
  class AiSettingsController < ApplicationController
    include AiSettingsResponses

    rate_limit to: MUTATION_LIMIT, within: MUTATION_WINDOW, by: -> { current_user.id }, name: "ai_settings",
               with: :render_rate_limited, only: :update

    def show
      @ai_settings = Accounts::AiSettings.state(current_user)
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
  end
end
