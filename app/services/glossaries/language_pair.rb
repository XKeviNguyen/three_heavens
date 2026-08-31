module Glossaries
  module LanguagePair
    # V1 language matching strips surrounding whitespace and compares labels case-insensitively.
    # It deliberately does not infer ISO aliases or language families.
    def self.matches?(revision, source_language:, target_language:)
      normalize(revision.source_language) == normalize(source_language) &&
        normalize(revision.target_language) == normalize(target_language)
    end

    def self.normalize(value)
      value.to_s.strip.downcase
    end
  end
end
