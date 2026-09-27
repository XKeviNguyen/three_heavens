module SourceImports
  class TextExtractor
    def self.call(format:, bytes:)
      raw_text = case format
      when "docx" then DocxExtractor.call(bytes)
      when "pdf" then PdfExtractor.call(bytes)
      else bytes
      end
      TextNormalizer.call(raw_text)
    end
  end
end
