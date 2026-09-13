require "stringio"

module SourceImports
  class Detector
    DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    DOCM_MIME = "application/vnd.ms-word.document.macroenabled.12"
    GENERIC_MIMES = [ "application/octet-stream", "application/zip" ].freeze
    TEXT_MIMES = %w[text/plain].freeze
    MARKDOWN_MIMES = %w[text/plain text/markdown text/x-markdown].freeze

    Result = Data.define(:format, :content_type)

    def self.call(filename:, bytes:, declared_content_type: nil)
      new(filename:, bytes:, declared_content_type:).call
    end

    def initialize(filename:, bytes:, declared_content_type:)
      @filename = filename
      @bytes = bytes
      @declared_content_type = declared_content_type.to_s.split(";", 2).first.to_s.strip.downcase.presence
    end

    def call
      extension = File.extname(filename).downcase
      format = Limits::EXTENSIONS[extension]
      unless format
        raise Error.new("unsupported_format", "Choose a .docx, .txt, or .md source file.")
      end

      detected = Marcel::MimeType.for(StringIO.new(bytes), name: filename)
      if format == "docx"
        validate_declared_type!([ DOCX_MIME, *GENERIC_MIMES ])
        unless bytes.start_with?("PK\x03\x04".b) && detected.in?([ DOCX_MIME, DOCM_MIME, *GENERIC_MIMES ])
          raise Error.new("mismatched_type", "The selected file is not a valid DOCX document.")
        end
        Result.new(format:, content_type: DOCX_MIME)
      else
        allowed_mimes = format == "md" ? MARKDOWN_MIMES : TEXT_MIMES
        validate_declared_type!(allowed_mimes + [ "application/octet-stream" ])
        allowed_mimes = allowed_mimes + [ "application/octet-stream" ] if bytes.empty?
        if bytes.start_with?("PK\x03\x04".b) || !allowed_mimes.include?(detected)
          raise Error.new("mismatched_type", "The selected file does not match its text-file extension.")
        end
        Result.new(format:, content_type: "text/plain")
      end
    end

    private

    attr_reader :filename, :bytes, :declared_content_type

    def validate_declared_type!(allowed)
      return if declared_content_type.nil? || allowed.include?(declared_content_type)

      raise Error.new("mismatched_type", "The selected file's type does not match its extension.")
    end
  end
end
