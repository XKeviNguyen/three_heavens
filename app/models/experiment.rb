class Experiment < ApplicationRecord
  belongs_to :document

  has_many :translation_runs, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true

  validates :name, length: { maximum: 150 }, allow_blank: true
end
