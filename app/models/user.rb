class User < ApplicationRecord
  EMAIL_PATTERN = /\A[^\s@]+@[^\s@]+\.[^\s@]+\z/
  MAXIMUM_EMAIL_LENGTH = 254
  MINIMUM_PASSWORD_LENGTH = 12
  MAXIMUM_PASSWORD_LENGTH = 128

  has_secure_password

  has_many :projects, dependent: :restrict_with_error
  has_many :source_imports, dependent: :restrict_with_error
  has_many :documents, through: :projects
  has_many :experiments, through: :documents
  has_many :review_rounds, through: :experiments
  has_many :judge_rounds, through: :review_rounds
  has_many :final_translations, through: :experiments
  has_many :workflow_profiles, dependent: :restrict_with_error
  has_many :pipeline_runs, through: :experiments
  has_many :translation_workspace_submissions, dependent: :restrict_with_error

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
            allow_nil: true

  def self.authenticate_by_email(email:, password:)
    account = authenticate_by(
      email: normalize_value_for(:email, email),
      password: password
    )
    account if account&.active?
  end
end
