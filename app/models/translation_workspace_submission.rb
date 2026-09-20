require "digest"
require "securerandom"

class TranslationWorkspaceSubmission < ApplicationRecord
  TOKEN_BYTES = 32
  TOKEN_LENGTH = 43
  TOKEN_FORMAT = /\A[A-Za-z0-9_-]{#{TOKEN_LENGTH}}\z/
  LIFETIME = 24.hours
  CLEANUP_BATCH_SIZE = 100

  attr_accessor :public_token

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

  def self.issue!(user:, at: Time.current)
    token = SecureRandom.urlsafe_base64(TOKEN_BYTES, false)
    create!(
      user: user,
      token_digest: digest(token),
      status: :available,
      expires_at: at + LIFETIME
    ).tap { |submission| submission.public_token = token }
  end

  def self.find_owned_by_token!(user:, token:)
    raise ActiveRecord::RecordNotFound, "Translation workspace submission not found" unless valid_public_token?(token)

    user.translation_workspace_submissions.find_by!(token_digest: digest(token))
  end

  def self.valid_public_token?(token)
    token.is_a?(String) && token.match?(TOKEN_FORMAT)
  end

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
