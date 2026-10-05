# An admission lease, not an authorization token. Ownership is still checked
# by each domain. A page may append fresh random action suffixes, but cannot
# extend the signed deadline of an old identity after its ledger is purged.
class ReplayIdentity
  LIFETIME = TranslationWorkspaceSubmission::LIFETIME
  LEGACY_FORMAT = /\A[0-9a-f]{32}\z/
  FORMAT = /\A[A-Za-z0-9_-]{16,200}--[0-9a-f]{64}\.[0-9a-f]{32}\z/
  PUBLIC_FORMAT = /\A(?:[0-9a-f]{32}|[A-Za-z0-9_-]{16,200}--[0-9a-f]{64}\.[0-9a-f]{32})\z/

  def self.lease(at: Time.current)
    verifier.generate({ "expires_at" => (at + LIFETIME).to_i })
  end

  def self.issue(at: Time.current)
    "#{lease(at:)}.#{SecureRandom.hex(16)}"
  end

  def self.expires_at(key)
    return unless key.is_a?(String) && key.match?(FORMAT)

    payload = verifier.verified(key.split(".", 2).first)
    return unless payload.is_a?(Hash) && payload["expires_at"].is_a?(Integer)

    Time.zone.at(payload.fetch("expires_at"))
  end

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
