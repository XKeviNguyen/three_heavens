require "pdf-reader"
require "stringio"
require "timeout"

module SourceImports
  class PdfExtractor
    def self.call(bytes)
      Timeout.timeout(Limits::MAX_PDF_PARSE_SECONDS) do
        reader = PDF::Reader.new(StringIO.new(bytes))
        if reader.objects.encrypted?
          raise Error.new("pdf_encrypted", "Encrypted or password-protected PDFs are not supported.")
        end
        if reader.page_count > Limits::MAX_PDF_PAGES
          raise Error.new("pdf_too_many_pages", "This PDF has too many pages to process safely.")
        end

        text = +""
        reader.pages.each do |page|
          text << "\n\n" unless text.empty?
          text << page.text.to_s
          if text.length > Limits::MAX_EXTRACTED_CHARACTERS
            raise Error.new("source_too_long", "The extracted source exceeds the character limit.")
          end
        end
        if text.strip.empty?
          raise Error.new("pdf_no_text", "This PDF does not contain extractable text. Scanned PDFs need OCR, which is not supported yet.")
        end
        text.delete("\0")
      end
    rescue Timeout::Error
      raise Error.new("pdf_timeout", "This PDF took too long to process.")
    rescue PDF::Reader::EncryptedPDFError
      raise Error.new("pdf_encrypted", "Encrypted or password-protected PDFs are not supported.")
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError,
           PDF::Reader::Error, ArgumentError, Encoding::InvalidByteSequenceError
      raise Error.new("malformed_pdf", "The selected PDF could not be read safely.")
    end
  end
end
