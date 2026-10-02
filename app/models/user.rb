class User < ApplicationRecord
  EMAIL_PATTERN = /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/
  MAXIMUM_EMAIL_LENGTH = 254
  MINIMUM_PASSWORD_LENGTH = 12
  MAXIMUM_PASSWORD_LENGTH = 128
  SUPPORTED_LOCALES = %w[en vi ja].freeze
  APPEARANCES = %w[system light dark].freeze

  generates_token_for :email_confirmation, expires_in: 24.hours do
    [ email, email_verified_at, confirmation_sent_at ].join(":")
  end

  # Accounts created through Sign in with Google have no password, so the
  # default presence validation is replaced below; the others are kept as-is.
  has_secure_password validations: false

  has_many :projects, dependent: :restrict_with_error
  has_many :source_imports, dependent: :restrict_with_error
  has_many :documents, through: :projects
  has_many :experiments, through: :documents
  has_many :review_rounds, through: :experiments
  has_many :judge_rounds, through: :review_rounds
  has_many :final_translations, through: :experiments
  has_many :workflow_profiles, dependent: :restrict_with_error
  has_many :glossaries, dependent: :restrict_with_error
  has_many :methodology_profiles, dependent: :restrict_with_error
  has_many :translation_references, dependent: :restrict_with_error
  has_many :pipeline_runs, through: :experiments
  has_many :translation_workspace_submissions, dependent: :restrict_with_error
  has_many :translation_workspace_drafts, dependent: :delete_all
  has_many :federated_identities, dependent: :delete_all
  has_many :sessions, dependent: :delete_all

  enum :role, { user: "user", admin: "admin" }, validate: true
  enum :status, { active: "active", disabled: "disabled" }, validate: true

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :email,
            presence: true,
            length: { maximum: MAXIMUM_EMAIL_LENGTH },
            format: { with: EMAIL_PATTERN },
            uniqueness: { case_sensitive: false }
  validates :password,
            length: { minimum: MINIMUM_PASSWORD_LENGTH, maximum: MAXIMUM_PASSWORD_LENGTH },
            confirmation: { allow_nil: true },
            allow_nil: true
  validate :password_within_bcrypt_limit
  validate :sign_in_method_present
  validates :locale, inclusion: { in: SUPPORTED_LOCALES }
  validates :appearance, inclusion: { in: APPEARANCES }

  def email_verified?
    email_verified_at.present?
  end

  def password_sign_in?
    password_digest.present?
  end

  # Accounts without a password still pay one bcrypt comparison, so password
  # sign-in timing does not reveal which accounts sign in only with Google.
  def authenticate_password(unencrypted_password)
    return super if password_sign_in?

    BCrypt::Password.new(self.class.timing_equalizer_digest).is_password?(unencrypted_password.to_s)
    false
  end

  def self.timing_equalizer_digest
    @timing_equalizer_digest ||= BCrypt::Password.create(
      SecureRandom.hex(16),
      cost: ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    ).to_s
  end

  def self.authenticate_by_email(email:, password:)
    account = authenticate_by(
      email: normalize_value_for(:email, email),
      password: password
    )
    account if account&.active?
  end

  private

  def password_within_bcrypt_limit
    return unless password.present? && password.bytesize > ActiveModel::SecurePassword::MAX_PASSWORD_LENGTH_ALLOWED

    errors.add(:password, :password_too_long)
  end

  def sign_in_method_present
    return if password_sign_in? || federated_identities.any?

    errors.add(:password, :blank)
  end
end
