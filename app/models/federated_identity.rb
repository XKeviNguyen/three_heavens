# An external identity-provider account that can sign in as a User. The
# provider's immutable subject identifier is the identity; email is never used
# as a key. No provider tokens are stored.
class FederatedIdentity < ApplicationRecord
  PROVIDERS = %w[google].freeze
  MAXIMUM_PROVIDER_UID_LENGTH = 255

  belongs_to :user

  validates :provider, inclusion: { in: PROVIDERS }, uniqueness: { scope: :user_id }
  validates :provider_uid,
            presence: true,
            length: { maximum: MAXIMUM_PROVIDER_UID_LENGTH },
            uniqueness: { scope: :provider }
end
