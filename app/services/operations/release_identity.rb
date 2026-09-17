module Operations
  class ReleaseIdentity
    SHA_FORMAT = /\A[0-9a-f]{7,64}\z/

    def self.call(environment: ENV)
      value = environment["KAMAL_VERSION"].presence || environment["RELEASE_SHA"].presence
      value.to_s.match?(SHA_FORMAT) ? value : "unknown"
    end
  end
end
