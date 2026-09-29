module GoogleIdentity
  # Resolves a verified Google identity to a local account for sign-in.
  #
  # - A known (google, sub) identity signs in its user, subject to local status
  #   and email verification. Google never overrides a disabled account.
  # - An unknown identity whose email already belongs to an account is never
  #   linked automatically; the owner must sign in and connect Google explicitly.
  # - Otherwise a normal user is created with server-controlled defaults (no
  #   admin role, no managed AI access), but only when Google is authoritative
  #   for the email. For any other address Google cannot prove current mailbox
  #   ownership, so no account is created: the person registers with email and
  #   password (which confirms the address) and then connects Google.
  class SignIn
    Result = Data.define(:status, :user) do
      def signed_in? = status == :signed_in
    end

    def self.call(...) = new(...).call

    def initialize(claims:, ceremony:)
      @claims = claims
      @ceremony = ceremony
    end

    def call
      identity = FederatedIdentity.find_by(provider: PROVIDER, provider_uid: @claims.subject)
      return result_for(identity.user) if identity
      return Result.new(status: :email_taken, user: nil) if User.exists?(email: @claims.email)
      return Result.new(status: :email_not_authoritative, user: nil) unless @claims.google_authoritative_email?

      result_for(create_user)
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      # A concurrent callback created the identity or took the email first.
      identity = FederatedIdentity.find_by(provider: PROVIDER, provider_uid: @claims.subject)
      identity ? result_for(identity.user) : Result.new(status: :email_taken, user: nil)
    end

    private

    def result_for(user)
      return Result.new(status: :disabled, user: nil) unless user.active?
      return Result.new(status: :confirmation_required, user: nil) unless user.email_verified?

      Result.new(status: :signed_in, user: user)
    end

    def create_user
      user = User.new(
        email: @claims.email,
        role: :user,
        status: :active,
        managed_ai_access: false,
        locale: @ceremony.locale || I18n.default_locale.to_s,
        appearance: @ceremony.appearance || "system",
        email_verified_at: Time.current
      )
      user.federated_identities.build(provider: PROVIDER, provider_uid: @claims.subject)
      user.save!
      user
    end
  end
end
