require "digest"

module LongDocuments
  class Segmenter
    VERSION = "semantic-boundaries-v2"
    TARGET_CHARACTERS = 4_000
    MIN_SEMANTIC_SPLIT_CHARACTERS = 1_000

    Segment = Data.define(:position, :source_text, :source_sha256)

    def self.call(source_text, target_characters: TARGET_CHARACTERS)
      new(source_text.to_s, target_characters: target_characters).call
    end

    def initialize(source_text, target_characters:)
      @source_text = source_text
      @target_characters = Integer(target_characters)
    end

    def call
      raise ArgumentError, "source text must be present" if source_text.blank?
      unless target_characters.between?(256, 20_000)
        raise ArgumentError, "segment target is outside the supported range"
      end

      remaining = source_text.dup
      parts = []
      while remaining.length > target_characters
        cut = preferred_cut(remaining[0, target_characters])
        parts << remaining.slice!(0, cut)
      end
      parts << remaining unless remaining.empty?
      # Whitespace belongs to adjacent source content, never a standalone
      # provider request. The target is soft; ContextBudget still bounds bytes.
      parts = parts.each_with_object([]) do |part, combined|
        if combined.any? && (part.blank? || combined.last.blank?)
          combined.last << part
        else
          combined << part
        end
      end

      segments = parts.each_with_index.map do |text, index|
        Segment.new(
          position: index + 1,
          source_text: text,
          source_sha256: Digest::SHA256.hexdigest(text)
        )
      end
      raise "segment reconstruction failed" unless segments.sum("", &:source_text) == source_text

      segments.freeze
    end

    private

    attr_reader :source_text, :target_characters

    def preferred_cut(window)
      minimum = [ MIN_SEMANTIC_SPLIT_CHARACTERS, window.length ].min
      candidates = [
        last_boundary(window, /\n[\t ]*\n+/),
        last_boundary(window, /\n/),
        last_boundary(window, /[.!?。！？](?:[\t ]+|\z)/)
      ]
      candidates.compact.find { |position| position >= minimum } || window.length
    end

    def last_boundary(window, pattern)
      match = nil
      window.to_enum(:scan, pattern).each { match = Regexp.last_match }
      match&.end(0)
    end
  end
end
