module Ai
  # The one policy deciding who pays for AI work and with which OpenRouter key.
  #
  # Account eligibility (active, verified email) is separate from payment
  # authorization:
  # - managed: the platform's server-owned key; needs the administrator's
  #   managed_ai_access permission.
  # - personal: the owner's own key; needs a configured (unrevoked) key and
  #   no administrator permission.
  #
  # Scheduling (authorize!) stamps the owner's explicitly selected source, and
  # for a personal key the exact key version, onto the work. Execution
  # (credential_for!) re-checks that stamp under the owner's row lock, which
  # key and preference changes also take, and never substitutes another
  # source or key: a revoked, replaced, or missing personal key, a withdrawn
  # managed permission, or an ineligible account fails the work closed.
  class BillingPolicy
    SOURCES = User::AI_PAYMENT_SOURCES

    class Denied < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(MESSAGES.fetch(code))
      end
    end

    MESSAGES = {
      "ai_account_ineligible" => "AI work requires an active account with a confirmed email address.",
      "managed_ai_access_revoked" => ManagedAccess::DENIED_MESSAGE,
      "personal_key_unavailable" => "The OpenRouter key this work was authorized with was replaced, deleted, or is missing. " \
                                    "Add a key in AI settings, then retry explicitly."
    }.freeze
    DENIAL_CODES = MESSAGES.keys.freeze

    # The payment identity recorded on authorized work. It holds no secret.
    Authorization = Data.define(:billing_source, :open_router_credential_id) do
      def self.from(record)
        new(billing_source: record.billing_source, open_router_credential_id: record.open_router_credential_id)
      end

      def personal?
        billing_source == "personal"
      end

      def attributes
        { billing_source: billing_source, open_router_credential_id: open_router_credential_id }
      end
    end

    def self.eligible?(user)
      user.active? && user.email_verified?
    end

    # What the owner's current explicit selection authorizes for new work.
    def self.authorize!(user)
      raise Denied, "ai_account_ineligible" unless eligible?(user)

      if user.ai_paid_by_personal?
        credential = user.open_router_credentials.active.pick(:id)
        raise Denied, "personal_key_unavailable" unless credential

        Authorization.new(billing_source: "personal", open_router_credential_id: credential)
      else
        raise Denied, "managed_ai_access_revoked" unless ManagedAccess.allowed?(user)

        Authorization.new(billing_source: "managed", open_router_credential_id: nil)
      end
    end

    def self.denial_for(user)
      authorize!(user)
      nil
    rescue Denied => denial
      denial
    end

    # Re-checks an earlier authorization (a stamped run or pipeline) without
    # decrypting anything. Callers that need the key use credential_for!.
    def self.verify!(authorization, user)
      raise Denied, "ai_account_ineligible" unless eligible?(user)

      if authorization.personal?
        raise Denied, "personal_key_unavailable" unless active_credential(authorization, user)
      else
        raise Denied, "managed_ai_access_revoked" unless ManagedAccess.allowed?(user)
      end
      authorization
    end

    # Resolves the key for a claimed run. The caller must hold the owner's
    # row lock so a concurrent key revocation commits entirely before or after.
    def self.credential_for!(run, user)
      authorization = Authorization.from(run)
      verify!(authorization, user)
      if authorization.personal?
        ProviderCredential.personal(active_credential(authorization, user).api_key)
      else
        ProviderCredential.managed
      end
    rescue ActiveRecord::Encryption::Errors::Base
      # Undecryptable ciphertext (for example after secret_key_base rotated
      # without re-encryption) is treated as a missing key, never as managed.
      raise Denied, "personal_key_unavailable"
    end

    def self.active_credential(authorization, user)
      OpenRouterCredential.active.find_by(id: authorization.open_router_credential_id, user_id: user.id)
    end
    private_class_method :active_credential
  end
end
