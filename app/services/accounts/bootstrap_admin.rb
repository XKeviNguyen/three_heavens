module Accounts
  class BootstrapAdmin
    class ConfigurationError < StandardError; end

    def self.call(email: nil, password: nil, environment: ENV, prompt: ConsolePrompt.new)
      new(email: email, password: password, environment: environment, prompt: prompt).call
    end

    def initialize(email:, password:, environment:, prompt:)
      @email = email
      @password = password
      @environment = environment
      @prompt = prompt
    end

    def call
      resolved_email = resolve_email
      resolved_password = resolve_password

      normalized_email = User.normalize_value_for(:email, resolved_email)
      User.transaction do
        account = User.find_or_initialize_by(email: normalized_email)
        # The operator supplied this address, so it counts as verified; sign-in
        # requires a verified address. Managed AI access stays an explicit grant.
        account.assign_attributes(
          password: resolved_password,
          password_confirmation: resolved_password,
          role: :admin,
          status: :active,
          email_verified_at: account.email_verified_at || Time.current
        )
        account.save!
        claim_legacy_projects!(account)
        account
      end
    end

    private

    attr_reader :email, :environment, :password, :prompt

    def resolve_email
      supplied = email.presence || environment["THREE_HEAVENS_ADMIN_EMAIL"].presence
      return supplied if supplied

      ensure_interactive!
      value = prompt.ask("Admin email: ").to_s.strip
      raise ConfigurationError, "Admin email cannot be blank" if value.blank?

      value
    end

    def resolve_password
      supplied = password.presence || environment["THREE_HEAVENS_ADMIN_PASSWORD"].presence
      return supplied if supplied

      ensure_interactive!
      entered = prompt.ask_secret("Admin password: ")
      confirmation = prompt.ask_secret("Confirm admin password: ")
      unless entered == confirmation
        raise ConfigurationError, "Admin password confirmation does not match"
      end
      raise ConfigurationError, "Admin password cannot be blank" if entered.blank?

      entered
    end

    def ensure_interactive!
      return if prompt.interactive?

      raise ConfigurationError,
            "Set THREE_HEAVENS_ADMIN_EMAIL and THREE_HEAVENS_ADMIN_PASSWORD, " \
            "or run this task from an interactive terminal"
    end

    def claim_legacy_projects!(account)
      legacy_owner_ids = User.disabled
        .where("email LIKE ?", "legacy-ownership-%@invalid.local")
        .select(:id)
      Project.where(user_id: legacy_owner_ids).update_all(
        user_id: account.id,
        updated_at: Time.current
      )
    end
  end
end
