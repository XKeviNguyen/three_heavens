module Accounts
  # The owner's AI payment settings: the selected source and their own
  # OpenRouter key. Every change locks the user row, the same lock
  # Ai::ExecutionClaim holds while resolving a run's key, so a claim sees a
  # key change either entirely or not at all.
  #
  # Each mutation carries the state token the form was rendered with. A token
  # that no longer matches (another tab, a double submit, a stale page) is
  # rejected rather than applied over a state the user did not see.
  class AiSettings
    class Error < StandardError; end

    class StaleError < Error; end

    class InvalidError < Error
      attr_reader :field

      def initialize(field, message)
        @field = field
        super(message)
      end
    end

    # Read under a share lock so the source, key, denial, and token all come
    # from one committed state, never from either side of a concurrent change.
    def self.state(user)
      user.with_lock("FOR SHARE") { snapshot(user) }
    end

    def self.snapshot(user)
      credential = user.open_router_credentials.active.select(:id, :key_hint, :created_at).first
      {
        payment_source: user.ai_payment_source,
        managed_access: Ai::ManagedAccess.allowed?(user),
        personal_key: credential ? { configured: true, hint: credential.key_hint, added_at: credential.created_at.iso8601 } : { configured: false },
        denial_code: Ai::BillingPolicy.denial_for(user)&.code,
        state_token: token_for(user.ai_payment_source, credential&.id)
      }
    end
    private_class_method :snapshot

    def self.select_source!(user, source:, state_token:)
      source = source.to_s
      unless User::AI_PAYMENT_SOURCES.include?(source)
        raise InvalidError.new(:payment_source, I18n.t("ai_settings.errors.source_invalid"))
      end

      change(user, state_token) do |credential|
        if source == "managed" && !Ai::ManagedAccess.allowed?(user)
          raise InvalidError.new(:payment_source, I18n.t("ai_settings.errors.managed_unavailable"))
        end
        if source == "personal" && credential.nil?
          raise InvalidError.new(:payment_source, I18n.t("ai_settings.errors.key_required"))
        end

        next if user.ai_payment_source == source

        user.update!(ai_payment_source: source)
        Operations::EventLogger.emit("ai_payment_source_changed", user_id: user.id, outcome: source)
      end
    end

    def self.store_key!(user, api_key:, state_token:)
      api_key = api_key.to_s.strip
      if api_key.empty?
        raise InvalidError.new(:api_key, I18n.t("ai_settings.errors.key_blank"))
      end
      unless api_key.length <= OpenRouterCredential::MAXIMUM_KEY_LENGTH && api_key.match?(OpenRouterCredential::KEY_PATTERN)
        raise InvalidError.new(:api_key, I18n.t("ai_settings.errors.key_format"))
      end

      change(user, state_token) do |credential|
        credential&.revoke!(reason: "replaced")
        user.open_router_credentials.create!(api_key: api_key)
        Operations::EventLogger.emit("open_router_key_changed", user_id: user.id, outcome: credential ? "replaced" : "added")
      end
    end

    def self.delete_key!(user, state_token:)
      change(user, state_token) do |credential|
        next unless credential

        credential.revoke!(reason: "deleted")
        Operations::EventLogger.emit("open_router_key_changed", user_id: user.id, outcome: "deleted")
      end
    end

    def self.change(user, state_token)
      user.with_lock do
        credential = user.open_router_credentials.active.first
        expected = token_for(user.ai_payment_source, credential&.id)
        supplied = state_token.to_s
        unless supplied.length == expected.length && ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
          raise StaleError
        end

        yield credential
        user.association(:open_router_credentials).reset
        snapshot(user)
      end
    end
    private_class_method :change

    def self.token_for(source, credential_id)
      "#{source}.#{credential_id || 0}"
    end
    private_class_method :token_for
  end
end
