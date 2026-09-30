require "pdf-reader"
require "stringio"

module SourceImports
  class PdfExtractor
    # The program PdfExtractor runs in its resource-limited child process. It
    # loads only pdf-reader, reads the PDF from standard input, and writes one
    # status line (`ok` or `error CODE`) followed by the extracted text. Any
    # other outcome, including running out of memory, ends the process without
    # a status line, which the parent treats as an unreadable PDF.
    module Worker
      Failure = Class.new(StandardError)

      def self.run(input: $stdin, output: $stdout, max_pages: Integer(ARGV.fetch(0)), max_characters: Integer(ARGV.fetch(1)))
        output.binmode
        text = extract(input.binmode.read, max_pages:, max_characters:)
        output.write("ok\n", text)
      rescue Failure => failure
        output.write("error #{failure.message}\n")
      rescue PDF::Reader::EncryptedPDFError
        output.write("error pdf_encrypted\n")
      rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError,
             PDF::Reader::Error, ArgumentError, Encoding::InvalidByteSequenceError
        output.write("error malformed_pdf\n")
      ensure
        output.flush
      end

      def self.extract(bytes, max_pages:, max_characters:)
        reader = PDF::Reader.new(StringIO.new(bytes))
        raise Failure, "pdf_encrypted" if reader.objects.encrypted?
        raise Failure, "pdf_too_many_pages" if reader.page_count > max_pages

        text = +""
        reader.pages.each do |page|
          text << "\n\n" unless text.empty?
          text << page.text.to_s
          raise Failure, "source_too_long" if text.length > max_characters
        end
        raise Failure, "pdf_no_text" if text.strip.empty?

        text.delete("\0")
      end
    end
  end
end
