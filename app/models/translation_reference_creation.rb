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
    transaction do
      ids = where(status: :failed).where(created_at: ..cutoff).order(:created_at, :id).limit(100)
        .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      where(id: ids, status: :failed).update_all(status: "expired", failure: nil, updated_at: Time.current)
    end
  end

  def recovery_expired?
    failed? && created_at <= FAILURE_RETENTION.ago
  end

  def self.lock_key(user_id:, creation_key:)
    Digest::SHA256.digest("reference_creation:#{user_id}:#{creation_key}").unpack1("q>")
  end

  # Every outcome is ephemeral coordination state. The referenced business
  # record survives deletion. Skip even expired pending rows while a live
  # creator owns the session lock; abandoned pending rows can be purged.
  def self.purge_expired(at: Time.current, batch_size: 100)
    limit = Integer(batch_size).clamp(1, 100)
    transaction do
      candidates = where(expires_at: ..at).order(:expires_at, :id).limit(limit)
        .lock("FOR UPDATE SKIP LOCKED").pluck(:id, :user_id, :creation_key)
      ids = candidates.filter_map do |id, user_id, creation_key|
        key = lock_key(user_id:, creation_key:)
        id if connection.select_value(sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(?)", key ]))
      end
      where(id: ids).delete_all
    end
  end
end
