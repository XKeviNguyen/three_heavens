# One version of a user's own OpenRouter API key. The key is stored only as
# Active Record Encryption ciphertext (config/initializers/active_record_encryption.rb)
# and is never rendered, serialized, logged, or passed to a job: it is
# decrypted only by Ai::BillingPolicy when a claimed provider run needs it.
# Replacing or deleting a key revokes its row and erases the ciphertext; the
# row stays so work authorized under it keeps its identity and fails closed.
class OpenRouterCredential < ApplicationRecord
  KEY_PATTERN = /\Ask-or-[A-Za-z0-9_-]{16,250}\z/
  MAXIMUM_KEY_LENGTH = 256
  REVOCATION_REASONS = %w[replaced deleted].freeze

  belongs_to :user

  encrypts :api_key

  scope :active, -> { where(revoked_at: nil) }

  validates :api_key, presence: true, length: { maximum: MAXIMUM_KEY_LENGTH }, format: { with: KEY_PATTERN },
                      if: :active?
  validates :api_key, absence: true, unless: :active?
  validates :revocation_reason, inclusion: { in: REVOCATION_REASONS }, unless: :active?
  validates :revocation_reason, absence: true, if: :active?
  validates :key_hint, length: { maximum: 16 }

  before_validation :derive_key_hint, if: -> { active? && will_save_change_to_api_key? }

  def active?
    revoked_at.nil?
  end

  # Writes without reading the old value: change tracking would decrypt it,
  # and an undecryptable key (secret_key_base rotated without re-encryption)
  # must still be replaceable and deletable. The database checks the result.
  def revoke!(reason:, at: Time.current)
    raise ArgumentError, "unknown revocation reason" unless REVOCATION_REASONS.include?(reason)

    update_columns(revoked_at: at, revocation_reason: reason, api_key: nil, updated_at: at)
  end

  # The key never appears in inspect output, error reports, or consoles.
  def inspect
    "#<#{self.class.name} id: #{id.inspect}, user_id: #{user_id.inspect}, active: #{active?}>"
  end

  private

  def derive_key_hint
    self.key_hint = api_key.to_s.match?(KEY_PATTERN) ? "…#{api_key.last(4)}" : nil
  end
end
