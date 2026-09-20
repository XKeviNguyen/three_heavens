module Operations
  class ReleaseIdentity
    SHA_FORMAT = /\A[0-9a-f]{7,64}\z/

    def self.call(environment: ENV)
      [ environment["KAMAL_VERSION"], environment["RELEASE_SHA"] ].find do |value|
        value.to_s.match?(SHA_FORMAT)
      end || "unknown"
    end
  end
end
