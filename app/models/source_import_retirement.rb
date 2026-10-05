class SourceImportRetirement < ApplicationRecord
  belongs_to :user
  attr_readonly :user_id, :request_key

  # Keep only the delivery identity until its admission lease expires.
  validates :request_key, format: { with: SourceImports::Limits::REQUEST_KEY_FORMAT }

  def self.purge_expired(at: Time.current, batch_size: 100)
    limit = Integer(batch_size).clamp(1, 100)
    transaction do
      ids = where(expires_at: ..at).order(:expires_at, :id).limit(limit).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      where(id: ids).delete_all
    end
  end
end
