class LlmModel < ApplicationRecord
  has_many :translation_runs, dependent: :restrict_with_error

  scope :active_openrouter, -> { where(active: true, gateway: "openrouter") }

  validates :gateway, presence: true
  validates :provider, presence: true
  validates :model_identifier,
            presence: true,
            uniqueness: { scope: :gateway }
  validates :display_name, presence: true
end
