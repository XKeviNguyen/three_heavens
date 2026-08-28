require "digest"
require "stringio"

module SourceImports
  class Create
    def self.call(user:, upload:)
      new(user:, upload:).call
    end

    def initialize(user:, upload:)
      @user = user
      @upload = upload
    end

    def call
      raise Error.new("missing_file", "Choose a source file to upload.") unless upload.respond_to?(:read)

      advertised_size = upload.respond_to?(:size) ? upload.size : nil
      reject_oversize! if advertised_size && advertised_size > Limits::MAX_UPLOAD_BYTES

      bytes = read_bounded
      filename = Filename.safe_original(upload.original_filename)
      detection = Detector.call(filename:, bytes:)
      source_import = create_pending_import(filename:, detection:, bytes:)

      begin
        extracted_text = TextExtractor.call(format: detection.format, bytes:)
        source_import.update!(
          status: :ready,
          extracted_text:,
          extraction_version: Limits::EXTRACTION_VERSION
        )
      rescue Error => error
        source_import.update!(
          status: :failed,
          failure_code: error.code,
          failure_message: error.message
        )
        raise Error.new(error.code, error.message, source_import:)
      end

      source_import
    ensure
      upload.rewind if upload.respond_to?(:rewind)
    end

    private

    attr_reader :user, :upload

    def read_bounded
      upload.rewind if upload.respond_to?(:rewind)
      bytes = upload.read(Limits::MAX_UPLOAD_BYTES + 1).to_s.b
      reject_oversize! if bytes.bytesize > Limits::MAX_UPLOAD_BYTES
      bytes
    end

    def reject_oversize!
      raise Error.new(
        "file_too_large",
        "The source file is larger than the #{Limits::MAX_UPLOAD_BYTES / 1.megabyte} MiB limit."
      )
    end

    def create_pending_import(filename:, detection:, bytes:)
      user.source_imports.create!(
        status: :pending,
        original_filename: filename,
        detected_content_type: detection.content_type,
        imported_format: detection.format,
        byte_size: bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(bytes),
        expires_at: Limits::IMPORT_EXPIRATION.from_now
      ).tap do |source_import|
        source_import.source_file.attach(
          io: StringIO.new(bytes),
          filename: filename,
          content_type: detection.content_type,
          identify: false
        )
      end
    end
  end
end
