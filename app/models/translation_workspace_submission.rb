require "digest"
require "securerandom"

# One launch identity for a translation workspace, so a duplicated, retried,
# or replayed launch starts at most one experiment.
#
# Rendering the workspace only issues a signed token that binds the owner and
# an expiry; it writes nothing. The durable row is created by the first launch
# attempt that presents the token, and every attempt then serializes on that
# row, so the first launch consumes it and any later one replays its result.
class TranslationWorkspaceSubmission < ApplicationRecord
  TOKEN_PURPOSE = "translation_workspace_submission/token"
  SIGNED_TOKEN_FORMAT = /\A[A-Za-z0-9_-]{16,400}--\h{64}\z/
  # Tokens issued before V1.1 were random and had their row created on render.
  LEGACY_TOKEN_FORMAT = /\A[A-Za-z0-9_-]{43}\z/
  LIFETIME = 24.hours
  CLEANUP_BATCH_SIZE = 100

  belongs_to :user
  belongs_to :experiment, optional: true

  enum :status, { available: "available", consumed: "consumed" }, validate: true

  validates :token_digest,
            presence: true,
            format: { with: /\A\h{64}\z/ },
            uniqueness: true
  validates :experiment_id, uniqueness: true, allow_nil: true
  validates :expires_at, presence: true
  validate :lifecycle_is_consistent
  validate :experiment_belongs_to_user

  scope :expired_available, ->(cutoff = Time.current) { available.where(expires_at: ..cutoff) }

  before_destroy :prevent_consumed_destruction

  def self.issue_token(user:, at: Time.current)
    token_verifier.generate({ "n" => SecureRandom.urlsafe_base64(24), "u" => user.id, "e" => (at + LIFETIME).to_i })
  end

  # Returns the submission for a presented token, creating it on first use.
  # Returns nil for a genuine token that expired before it was ever used.
  # Raises RecordNotFound for a token not issued to this user.
  def self.claim!(user:, token:, at: Time.current)
    raise ActiveRecord::RecordNotFound, "Translation workspace submission not found" unless valid_public_token?(token)

    existing = user.translation_workspace_submissions.find_by(token_digest: digest(token))
    return existing if existing

    expires_at = signed_expiry(user:, token:)
    raise ActiveRecord::RecordNotFound, "Translation workspace submission not found" unless expires_at
    return if expires_at <= at

    # Concurrent first attempts race here; exactly one row is inserted.
    insert(
      { user_id: user.id, token_digest: digest(token), status: "available", expires_at:, created_at: at, updated_at: at },
      unique_by: :token_digest
    )
    user.translation_workspace_submissions.find_by!(token_digest: digest(token))
  end

  def self.valid_public_token?(token)
    token.is_a?(String) && (token.match?(SIGNED_TOKEN_FORMAT) || token.match?(LEGACY_TOKEN_FORMAT))
  end

  def self.signed_expiry(user:, token:)
    payload = token_verifier.verified(token)
    return unless payload.is_a?(Hash) && payload["n"].is_a?(String) && payload["u"] == user.id && payload["e"].is_a?(Integer)

    Time.zone.at(payload["e"])
  end

  def self.token_verifier
    ActiveSupport::MessageVerifier.new(
      Rails.application.key_generator.generate_key(TOKEN_PURPOSE),
      digest: "SHA256", serializer: JSON, url_safe: true
    )
  end
  private_class_method :signed_expiry, :token_verifier

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end
  private_class_method :digest

  def expired?(at: Time.current)
    available? && expires_at <= at
  end

  private

  def lifecycle_is_consistent
    consistent = if consumed?
      consumed_at.present? && experiment_id.present?
    else
      consumed_at.nil? && experiment_id.nil?
    end
    errors.add(:status, "must match its consumed result") unless consistent
  end

  def prevent_consumed_destruction
    return unless consumed?

    errors.add(:base, "Consumed workspace submissions preserve launch history")
    throw :abort
  end

  def experiment_belongs_to_user
    return unless experiment
    return if experiment.document.project.user_id == user_id

    errors.add(:experiment, "must belong to the submission owner")
  end
end
