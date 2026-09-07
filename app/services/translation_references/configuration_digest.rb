require "digest"
require "json"

module TranslationReferences
  class ConfigurationDigest
    def self.call(revision)
      canonical = {
        "source_language" => revision.source_language,
        "target_language" => revision.target_language,
        "source_text" => revision.source_text,
        "approved_translation" => revision.approved_translation
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end
  end
end
