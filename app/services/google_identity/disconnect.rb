module GoogleIdentity
  # Removes the user's Google identity unless it is their only way to sign in.
  class Disconnect
    def self.call(user:)
      user.with_lock do
        identity = user.federated_identities.find_by(provider: PROVIDER)
        return :not_connected unless identity
        return :only_sign_in_method unless user.password_sign_in? || user.federated_identities.where.not(id: identity.id).exists?

        identity.destroy!
        :disconnected
      end
    end
  end
end
