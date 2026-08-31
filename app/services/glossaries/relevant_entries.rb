module Glossaries
  class RelevantEntries
    def self.call(revision:, source_text:)
      return [] unless revision

      source = source_text.to_s
      revision.entries.select { |entry| source.include?(entry.source_term) }
        .sort_by { |entry| [ -entry.source_term.length, entry.source_term, entry.position ] }
        .first(GlossaryRevision::MAXIMUM_ENTRIES)
    end
  end
end
