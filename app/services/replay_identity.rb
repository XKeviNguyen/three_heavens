# Admission metadata, not authorization. Upload actions may append suffixes
# under their independent upload budget. Editors and references require a
# complete signed nonce; editor claims also bind the owner and context.
class ReplayIdentity
  LIFETIME = TranslationWorkspaceSubmission::LIFETIME
  LEGACY_FORMAT = /\A[0-9a-f]{32}\z/
  FORMAT = /\A[A-Za-z0-9_-]{16,255}--[0-9a-f]{64}\.[0-9a-f]{32}\z/
  PUBLIC_FORMAT = /\A(?:[0-9a-f]{32}|[A-Za-z0-9_-]{16,255}--[0-9a-f]{64}\.[0-9a-f]{32})\z/
  MAX_IDENTITIES_PER_USER = 256
  class AdmissionExceeded < StandardError; end

  def self.lease(at: Time.current)
    verifier.generate({ "expires_at" => (at + LIFETIME).to_i })
  end

  def self.issue(at: Time.current, user: nil, context_key: nil)
    identity = SecureRandom.hex(16)
    payload = { "expires_at" => (at + LIFETIME).to_i, "identity" => identity }
    payload.merge!("user_id" => user.id, "context_key" => context_key) if user
    "#{verifier.generate(payload)}.#{identity}"
  end

  def self.expires_at(key)
    return unless key.is_a?(String) && key.match?(FORMAT)

    payload = verified_payload(key)
    return unless payload.is_a?(Hash) && payload["expires_at"].is_a?(Integer)

    Time.zone.at(payload.fetch("expires_at"))
  end

  def self.complete?(key, user: nil, context_key: nil)
    payload = verified_payload(key)
    return false unless payload.is_a?(Hash) && payload["identity"] == key.split(".", 2).last

    !user || (payload["user_id"] == user.id && payload["context_key"] == context_key)
  end

  # Only first admissions use this lock; retries do not write counters. The
  # indexed owner count bounds state before insertion across concurrent pages.
  def self.admit!(ledger:, user:, identity:, scope: nil)
    lock_key = Digest::SHA256.digest("replay_admission:#{ledger.table_name}:#{user.id}").unpack1("q>")
    ledger.connection.select_value(ledger.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", lock_key ]))
    scope ||= ledger.where(user_id: user.id)
    return if scope.where(identity).exists?
    raise AdmissionExceeded if scope.limit(MAX_IDENTITIES_PER_USER).count >= MAX_IDENTITIES_PER_USER
  end

  def self.verified_payload(key)
    return unless key.is_a?(String) && key.match?(FORMAT)

    verifier.verified(key.split(".", 2).first)
  end
  private_class_method :verified_payload

  # Legacy random identities can only replay existing records, during their
  # conservative upgrade grace period. They can never create missing state.
  def self.valid?(key, existing: nil, at: Time.current)
    deadline = expires_at(key)
    deadline ||= existing&.expires_at if key.is_a?(String) && key.match?(LEGACY_FORMAT)
    deadline.present? && deadline > at
  end

  def self.verifier
    ActiveSupport::MessageVerifier.new(Rails.application.key_generator.generate_key("replay_identity/lease"),
      digest: "SHA256", serializer: JSON, url_safe: true)
  end
  private_class_method :verifier
end
