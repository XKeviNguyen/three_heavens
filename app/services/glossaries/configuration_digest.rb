require "digest"
require "json"

module Glossaries
  class ConfigurationDigest
    def self.call(revision)
      canonical = {
        "source_language" => revision.source_language,
        "target_language" => revision.target_language,
        "entries" => revision.entries.sort_by(&:position).map do |entry|
          {
            "position" => entry.position,
            "source_term" => entry.source_term,
            "preferred_target_term" => entry.preferred_target_term,
            "note" => entry.note
          }
        end
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end
  end
end
