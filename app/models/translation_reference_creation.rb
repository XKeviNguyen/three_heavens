class TranslationReferenceCreation < ApplicationRecord
  FAILURE_RETENTION = 24.hours
  MAX_FAILURE_BYTES = 2.megabytes
  RECOVERY_FIELD_LIMITS = {
    "title" => 150, "source_language" => 100, "target_language" => 100,
    "source_text" => TranslationReferenceRevision::MAXIMUM_SOURCE_CHARACTERS,
    "approved_translation" => TranslationReferenceRevision::MAXIMUM_TRANSLATION_CHARACTERS
  }.freeze
  belongs_to :user
  belongs_to :translation_reference, optional: true
  enum :status, { pending: "pending", completed: "completed", failed: "failed", expired: "expired" }, validate: true
  attr_readonly :user_id, :creation_key, :payload_digest
  # Failed file extraction may have resolved one side. Keep only the form
  # recovery outcome, encrypted just like workspace drafts; never raw files.
  encrypts :failure

  def self.expire_failures(cutoff: FAILURE_RETENTION.ago)
    ids = where(status: :failed).where(created_at: ..cutoff).order(:created_at, :id).limit(100).pluck(:id)
    where(id: ids, status: :failed).update_all(status: "expired", failure: nil, updated_at: Time.current)
  end

  def recovery_expired?
    failed? && created_at <= FAILURE_RETENTION.ago
  end
end
