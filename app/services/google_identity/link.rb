module GoogleIdentity
  # Connects a freshly verified Google identity to the signed-in user. The
  # identity always attaches to that user; one owned by anyone else is refused
  # without revealing who owns it.
  class Link
    def self.call(user:, pending:)
      return :expired unless pending&.for?(user)

      user.with_lock do
        owner_id = FederatedIdentity.where(provider: PROVIDER, provider_uid: pending.subject).pick(:user_id)
        return :already_connected if owner_id == user.id
        return :taken if owner_id
        return :other_connected if user.federated_identities.exists?(provider: PROVIDER)

        user.federated_identities.create!(provider: PROVIDER, provider_uid: pending.subject)
        :connected
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      :taken
    end
  end
end
