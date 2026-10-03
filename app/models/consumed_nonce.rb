# A single-use value that has been spent. The unique index decides the first
# use atomically across every process and thread: exactly one insert of a
# digest succeeds, and every later or simultaneous one inserts nothing. Only
# a digest is stored. A row is needed only until the value it records could
# no longer be accepted anyway; SessionCleanupJob then deletes it.
class ConsumedNonce < ApplicationRecord
  scope :expired, -> { where(expires_at: ...Time.current) }

  # True only for the one caller that records this value first.
  def self.consume(namespace, value, expires_at:)
    digest = OpenSSL::Digest::SHA256.hexdigest("#{namespace}:#{value}")
    insert({ digest:, expires_at:, created_at: Time.current }, unique_by: :digest, returning: :digest).rows.any?
  end
end
