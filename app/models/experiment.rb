class Experiment < ApplicationRecord
  belongs_to :document

  has_many :translation_runs, dependent: :restrict_with_error
  has_one :review_round, dependent: :restrict_with_error
  has_one :judge_round, through: :review_round
  has_one :final_translation, dependent: :restrict_with_error
  has_one :pipeline_run, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :name, length: { maximum: 150 }, allow_blank: true
  validates :instruction_prompt,
            presence: true,
            length: { maximum: Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS }
end
