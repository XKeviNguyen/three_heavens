module Glossaries
  class BuildRevision
    class Error < StandardError; end

    def self.call(glossary:, version:, attributes:)
      new(glossary:, version:, attributes:).call
    end

    def initialize(glossary:, version:, attributes:)
      @glossary = glossary
      @version = version
      @attributes = attributes.to_h.stringify_keys
    end

    def call
      entries = attributes.fetch("entries", [])
      unless entries.is_a?(Array) && entries.size.between?(1, GlossaryRevision::MAXIMUM_ENTRIES)
        raise Error, "Provide 1-#{GlossaryRevision::MAXIMUM_ENTRIES} glossary entries"
      end

      revision = glossary.revisions.build(
        version: version,
        name: attributes.fetch("name", ""),
        description: attributes["description"],
        source_language: attributes.fetch("source_language", ""),
        target_language: attributes.fetch("target_language", "")
      )
      entries.each_with_index do |entry, index|
        entry = entry.to_h.stringify_keys
        revision.entries.build(
          position: index + 1,
          source_term: entry.fetch("source_term", ""),
          preferred_target_term: entry.fetch("preferred_target_term", ""),
          note: entry["note"]
        )
      end
      revision
    end

    private

    attr_reader :attributes, :glossary, :version
  end
end
