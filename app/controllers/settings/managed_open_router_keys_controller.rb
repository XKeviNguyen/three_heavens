module Settings
  # Admin → AI key: sets, replaces, or removes the app-wide OpenRouter key
  # that pays for managed AI work. Without a saved key, managed work uses the
  # server's OPENROUTER_API_KEY. The key is accepted only in a request body,
  # checked with OpenRouter before it is saved, and never returned.
  class ManagedOpenRouterKeysController < ApplicationController
    MUTATION_LIMIT = 10
    MUTATION_WINDOW = 1.minute

    class_attribute :key_status, instance_writer: false, default: OpenRouter::KeyStatus

    before_action :require_admin
    before_action { response.headers["Cache-Control"] = "no-store" }
    rate_limit to: MUTATION_LIMIT, within: MUTATION_WINDOW, by: -> { current_user.id }, name: "managed_open_router_key",
               only: %i[update destroy], with: -> { redirect_back_to_page(alert: t("managed_key.errors.rate_limited")) }

    def show
      @saved_key = ManagedOpenRouterKey.current
      environment_key = ENV["OPENROUTER_API_KEY"].presence
      @source = if @saved_key&.readable? then "saved"
      elsif @saved_key then "unreadable"
      elsif environment_key then "environment"
      else "missing"
      end
      @hint = @source == "saved" ? @saved_key.key_hint : environment_key && "…#{environment_key.last(4)}"
      @status = key_status.cached(ManagedOpenRouterKey.effective_api_key)
    end

    def update
      api_key = params.expect(managed_open_router_key: [ :api_key ])[:api_key].to_s.strip
      unless api_key.length <= OpenRouterCredential::MAXIMUM_KEY_LENGTH && api_key.match?(OpenRouterCredential::KEY_PATTERN)
        return redirect_back_to_page(alert: t("managed_key.errors.format"))
      end

      expected_id = expected_key_id
      # Checked before any lock is taken: the request may wait on OpenRouter.
      status = key_status.call(api_key)
      return redirect_back_to_page(alert: t("key_status.rejected")) if status.invalid?

      outcome = ManagedOpenRouterKey.store!(api_key, by: current_user, expected_id: expected_id)
      Operations::EventLogger.emit("managed_open_router_key_changed", actor_id: current_user.id, outcome: outcome)
      redirect_back_to_page(notice: t(status.valid? ? "managed_key.flash.saved" : "managed_key.flash.saved_unverified"))
    rescue ManagedOpenRouterKey::ConcurrentChange
      redirect_back_to_page(alert: t("managed_key.errors.stale"))
    end

    def destroy
      outcome = ManagedOpenRouterKey.delete!(expected_id: expected_key_id)
      Operations::EventLogger.emit("managed_open_router_key_changed", actor_id: current_user.id, outcome: outcome) if outcome
      redirect_back_to_page(notice: t("managed_key.flash.deleted"))
    rescue ManagedOpenRouterKey::ConcurrentChange
      redirect_back_to_page(alert: t("managed_key.errors.stale"))
    end

    private

    # The key the page showed when it was rendered; blank means no saved key.
    def expected_key_id
      value = params[:expected_key_id]
      return nil if value.blank?
      raise ActionController::BadRequest, "expected_key_id must be a single id" unless value.is_a?(String) && value.match?(/\A[1-9][0-9]{0,18}\z/)

      Integer(value, 10)
    end

    def redirect_back_to_page(**flash)
      redirect_to settings_managed_open_router_key_path, status: :see_other, **flash
    end
  end
end
