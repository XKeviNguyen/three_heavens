require "digest"
require "stringio"

module SourceImports
  # Stores one upload action as exactly one SourceImport and one blob.
  #
  # The browser sends a random request key per chosen file. A replayed,
  # retried, or concurrently duplicated delivery of that action resolves to
  # the import the first delivery created (same outcome, no new blob); a new
  # upload of the same file from a new action gets a new key and a new import.
  # Extraction runs before anything is written, and the row, blob, and
  # attachment commit together, so a failed or losing delivery leaves nothing
  # behind.
  class Create
    def self.call(user:, upload:, request_key:)
      new(user:, upload:, request_key:).call
    end

    def initialize(user:, upload:, request_key:)
      @user = user
      @upload = upload
      @request_key = request_key
    end

    def call
      raise ArgumentError, "invalid source import request key" unless request_key.to_s.match?(Limits::REQUEST_KEY_FORMAT)

      payload = UploadPayload.call(upload:)
      existing = user.source_imports.find_by(request_key:)
      return replay(existing, payload) if existing

      extracted_text = failure = nil
      begin
        extracted_text = TextExtractor.call(format: payload.detection.format, bytes: payload.bytes)
      rescue Error => error
        failure = error
      end
      source_import = create_import(payload:, extracted_text:, failure:)
      raise Error.new(failure.code, failure.message, source_import:) if failure

      source_import
    rescue ActiveRecord::RecordNotUnique
      replay(user.source_imports.find_by!(request_key:), payload)
    ensure
      upload.rewind if upload.respond_to?(:rewind)
    end

    private

    attr_reader :request_key, :user, :upload

    # Active Storage writes the file after the transaction commits. If that
    # write fails, the committed import is removed (purging its blob) so no
    # durable record points at missing bytes, and the error propagates.
    def create_import(payload:, extracted_text:, failure:)
      created = nil
      SourceImport.transaction(requires_new: true) do
        created = user.source_imports.create!(import_attributes(payload:, extracted_text:, failure:))
        created.source_file.attach(
          io: StringIO.new(payload.bytes),
          filename: payload.filename,
          content_type: payload.detection.content_type,
          identify: false
        )
      end
      created
    rescue ActiveRecord::RecordNotUnique
      raise
    rescue StandardError
      SourceImport.find_by(id: created.id)&.destroy! if created&.id
      raise
    end

    def import_attributes(payload:, extracted_text:, failure:)
      outcome = if failure
        { status: :failed, failure_code: failure.code, failure_message: failure.message }
      else
        { status: :ready, extracted_text:, extraction_version: Limits::EXTRACTION_VERSION }
      end
      {
        request_key:,
        original_filename: payload.filename,
        detected_content_type: payload.detection.content_type,
        imported_format: payload.detection.format,
        byte_size: payload.bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(payload.bytes),
        expires_at: Limits::IMPORT_EXPIRATION.from_now
      }.merge(outcome)
    end

    # A replay must carry the same file; it then reports the original outcome.
    def replay(source_import, payload)
      unless source_import.sha256 == Digest::SHA256.hexdigest(payload.bytes) &&
          source_import.original_filename == payload.filename
        raise Error.new("request_key_reused", "This upload was already submitted with a different file.")
      end
      if source_import.failed?
        raise Error.new(source_import.failure_code, source_import.failure_message, source_import:)
      end
      unless source_import.available?
        raise Error.new("import_unavailable", "This upload is no longer available. Upload the file again.", source_import:)
      end

      source_import
    end
  end
end
