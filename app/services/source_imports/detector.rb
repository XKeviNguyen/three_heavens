require "stringio"

module SourceImports
  class Detector
    DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    DOCM_MIME = "application/vnd.ms-word.document.macroenabled.12"
    TEXT_MIMES = %w[text/plain text/markdown].freeze
    MARKDOWN_MIMES = (TEXT_MIMES + %w[text/html application/xml]).freeze

    Result = Data.define(:format, :content_type)

    def self.call(filename:, bytes:)
      new(filename: filename, bytes: bytes).call
    end

    def initialize(filename:, bytes:)
      @filename = filename
      @bytes = bytes
    end

    def call
      extension = File.extname(filename).downcase
      format = Limits::EXTENSIONS[extension]
      unless format
        raise Error.new("unsupported_format", "Choose a .docx, .txt, or .md source file.")
      end

      detected = Marcel::MimeType.for(StringIO.new(bytes), name: filename)
      if format == "docx"
        unless bytes.start_with?("PK\x03\x04".b) && detected.in?([ DOCX_MIME, DOCM_MIME, "application/zip" ])
          raise Error.new("mismatched_type", "The selected file is not a valid DOCX document.")
        end
        Result.new(format:, content_type: DOCX_MIME)
      else
        allowed_mimes = format == "md" ? MARKDOWN_MIMES : TEXT_MIMES
        allowed_mimes = allowed_mimes + [ "application/octet-stream" ] if bytes.empty?
        if bytes.start_with?("PK\x03\x04".b) || !allowed_mimes.include?(detected)
          raise Error.new("mismatched_type", "The selected file does not match its text-file extension.")
        end
        Result.new(format:, content_type: "text/plain")
      end
    end

    private

    attr_reader :filename, :bytes
  end
end
