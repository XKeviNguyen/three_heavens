# One version of the app-wide OpenRouter key that pays for managed AI work.
# Like OpenRouterCredential, the key is stored only as Active Record
# Encryption ciphertext and is never rendered, serialized, logged, or passed
# to a job. Replacing or deleting it revokes the row and erases the
# ciphertext. With no active row, managed work uses OPENROUTER_API_KEY.
class ManagedOpenRouterKey < ApplicationRecord
  REVOCATION_REASONS = OpenRouterCredential::REVOCATION_REASONS

  class ConcurrentChange < StandardError; end

  belongs_to :created_by, class_name: "User", optional: true

  encrypts :api_key

  scope :active, -> { where(revoked_at: nil) }

  validates :api_key, presence: true, length: { maximum: OpenRouterCredential::MAXIMUM_KEY_LENGTH },
                      format: { with: OpenRouterCredential::KEY_PATTERN }, if: :active?
  validates :api_key, absence: true, unless: :active?
  validates :revocation_reason, inclusion: { in: REVOCATION_REASONS }, unless: :active?
  validates :revocation_reason, absence: true, if: :active?
  validates :key_hint, length: { maximum: 16 }

  before_validation :derive_key_hint, if: -> { active? && will_save_change_to_api_key? }

  def self.current
    active.order(:id).last
  end

  # The key managed work runs on: the admin-saved key, else the server's
  # environment. An undecryptable saved key (secret_key_base rotated without
  # re-encryption) falls back to the environment, which pays for the same
  # managed work.
  def self.effective_api_key
    current&.api_key.presence || ENV["OPENROUTER_API_KEY"].presence
  rescue ActiveRecord::Encryption::Errors::Decryption
    Rails.logger.warn("The saved managed OpenRouter key cannot be decrypted; using OPENROUTER_API_KEY")
    ENV["OPENROUTER_API_KEY"].presence
  end

  def readable?
    api_key.present?
  rescue ActiveRecord::Encryption::Errors::Decryption
    false
  end

  def self.store!(api_key, by:)
    transaction do
      previous = active.lock.first
      previous&.revoke!(reason: "replaced")
      create!(api_key: api_key, created_by: by)
      previous ? "replaced" : "added"
    end
  rescue ActiveRecord::RecordNotUnique
    raise ConcurrentChange
  end

  def self.delete!
    transaction do
      previous = active.lock.first
      previous&.revoke!(reason: "deleted")
      previous ? "deleted" : nil
    end
  end

  def active?
    revoked_at.nil?
  end

  # Writes without reading the old value, as OpenRouterCredential#revoke! does.
  def revoke!(reason:, at: Time.current)
    raise ArgumentError, "unknown revocation reason" unless REVOCATION_REASONS.include?(reason)

    update_columns(revoked_at: at, revocation_reason: reason, api_key: nil, updated_at: at)
  end

  def inspect
    "#<#{self.class.name} id: #{id.inspect}, active: #{active?}>"
  end

  private

  def derive_key_hint
    self.key_hint = api_key.to_s.match?(OpenRouterCredential::KEY_PATTERN) ? "…#{api_key.last(4)}" : nil
  end
end
