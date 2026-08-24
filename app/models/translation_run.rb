class TranslationRun < ApplicationRecord
  belongs_to :experiment
  belongs_to :llm_model

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }, validate: true
end
