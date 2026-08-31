require "digest"
require "json"

module MethodologyProfiles
  class ConfigurationDigest
    def self.call(revision)
      canonical = {
        "source_language" => revision.source_language,
        "target_language" => revision.target_language,
        "guidance" => revision.guidance
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end
  end
end
