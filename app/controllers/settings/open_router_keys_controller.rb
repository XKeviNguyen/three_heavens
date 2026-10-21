module Settings
  # Adds, replaces, or deletes the signed-in user's own OpenRouter key. The
  # key is accepted only in a request body and is never returned.
  class OpenRouterKeysController < ApplicationController
    include AiSettingsResponses

    class_attribute :key_status, instance_writer: false, default: OpenRouter::KeyStatus

    rate_limit to: MUTATION_LIMIT, within: MUTATION_WINDOW, by: -> { current_user.id }, name: "open_router_key",
               with: :render_rate_limited

    def update
      attributes = params.expect(open_router_key: %i[api_key state_token])
      # A well-formed key is checked with OpenRouter before any lock is taken;
      # one OpenRouter rejects is not saved. If OpenRouter cannot be reached,
      # the key is saved and its status shows on the page.
      api_key = attributes[:api_key].to_s.strip
      if api_key.match?(OpenRouterCredential::KEY_PATTERN) && key_status.call(api_key).invalid?
        return render_settings_error(t("key_status.rejected"), status: :unprocessable_content, field: :api_key)
      end
      respond_with_settings(notice: t("ai_settings.flash.key_saved")) do
        Accounts::AiSettings.store_key!(
          current_user,
          api_key: attributes[:api_key],
          state_token: attributes[:state_token]
        )
      end
    end

    def destroy
      attributes = params.expect(open_router_key: %i[state_token])
      respond_with_settings(notice: t("ai_settings.flash.key_deleted")) do
        Accounts::AiSettings.delete_key!(current_user, state_token: attributes[:state_token])
      end
    end
  end
end
