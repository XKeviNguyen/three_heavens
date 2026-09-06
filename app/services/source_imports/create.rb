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
      payload = UploadPayload.call(upload:)
      source_import = create_pending_import(
        filename: payload.filename,
        detection: payload.detection,
        bytes: payload.bytes
      )

      begin
        extracted_text = TextExtractor.call(
          format: payload.detection.format,
          bytes: payload.bytes
        )
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
