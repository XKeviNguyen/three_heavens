module SourceImports
  class TextExtractor
    def self.call(format:, bytes:)
      raw_text = format == "docx" ? DocxExtractor.call(bytes) : bytes
      TextNormalizer.call(raw_text)
    end
  end
end
