module Accounts
  class BootstrapAdmin
    class ConfigurationError < StandardError; end

    def self.call(email: ENV["THREE_HEAVENS_ADMIN_EMAIL"], password: ENV["THREE_HEAVENS_ADMIN_PASSWORD"])
      new(email: email, password: password).call
    end

    def initialize(email:, password:)
      @email = email
      @password = password
    end

    def call
      unless email.present? && password.present?
        raise ConfigurationError,
              "Set THREE_HEAVENS_ADMIN_EMAIL and THREE_HEAVENS_ADMIN_PASSWORD"
      end

      normalized_email = User.normalize_value_for(:email, email)
      User.transaction do
        account = User.find_or_initialize_by(email: normalized_email)
        account.assign_attributes(
          password: password,
          password_confirmation: password,
          role: :admin,
          status: :active
        )
        account.save!
        claim_legacy_projects!(account)
        account
      end
    end

    private

    attr_reader :email, :password

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
