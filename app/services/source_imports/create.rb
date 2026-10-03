require "digest"
require "stringio"

module SourceImports
  # Stores one upload action as exactly one SourceImport and one blob.
  #
  # The browser sends a random request key per upload action. Every delivery
  # of that action holds a per-key database lock while it runs, so a replayed,
  # retried, or concurrently duplicated delivery waits for the first one and
  # then reports its final outcome (the same import, or the same failure)
  # without extracting or storing again. A new upload of the same file is a
  # new action with a new key and a new import.
  #
  # An import stays pending until Active Storage has durably written its
  # object (after the row, blob, and attachment commit) and only then becomes
  # ready. If that write fails, the import becomes failed and its blob is
  # removed. No delivery can therefore report success for bytes that are not
  # stored, and no failed or losing delivery leaves an orphan blob behind.
  class Create
    STORAGE_FAILURE_MESSAGE = "The file could not be stored. Choose it again and retry."

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
      with_request_lock do
        existing = user.source_imports.find_by(request_key:)
        next replay(existing, payload) if existing

        store(payload)
      end
    ensure
      upload.rewind if upload.respond_to?(:rewind)
    end

    private

    attr_reader :request_key, :user, :upload

    def store(payload)
      extracted_text = failure = nil
      begin
        extracted_text = TextExtractor.call(format: payload.detection.format, bytes: payload.bytes)
      rescue Busy
        raise
      rescue Error => error
        failure = error
      end
      source_import = create_import(payload:, extracted_text:, failure:)
      failure ||= storage_failure unless source_import.ready?
      raise Error.new(failure.code, failure.message, source_import:) if failure

      source_import
    end

    # Active Storage writes the object after the transaction commits, so the
    # import is committed as pending and becomes ready only once that write
    # has returned. A failure before the commit leaves nothing behind; a
    # failure after it marks the import failed and removes its blob.
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
      created.update!(status: :ready) unless failure
      created
    rescue StandardError => error
      raise unless created&.id && SourceImport.exists?(created.id)

      Rails.logger.error("source_import_storage_failed source_import_id=#{created.id} error=#{error.class}")
      discard_unstored_object!(SourceImport.find(created.id), failure)
    end

    def discard_unstored_object!(source_import, failure)
      source_import.source_file.purge if source_import.source_file.attached?
      outcome = failure || storage_failure
      source_import.update!(
        status: :failed, extracted_text: nil, extraction_version: nil,
        failure_code: outcome.code, failure_message: outcome.message
      )
      source_import
    end

    def storage_failure
      Error.new("storage_unavailable", STORAGE_FAILURE_MESSAGE)
    end

    def import_attributes(payload:, extracted_text:, failure:)
      outcome = if failure
        { status: :failed, failure_code: failure.code, failure_message: failure.message }
      else
        { status: :pending, extracted_text:, extraction_version: Limits::EXTRACTION_VERSION }
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
    # Because the first delivery held the lock until its outcome was final, a
    # pending import here belongs to a delivery that died mid-way and is
    # reported as unavailable, never as success.
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

    # A session-level advisory lock, so it spans the separate transactions of
    # one delivery. Waiting is bounded; a delivery that cannot get the lock in
    # time reports that the upload is still in progress.
    def with_request_lock
      connection = SourceImport.connection
      lock_key = Digest::SHA256.digest("source_import_request:#{user.id}:#{request_key}").unpack1("q>")
      SourceImport.transaction(requires_new: true) do
        connection.execute("SET LOCAL lock_timeout = '#{Limits::REQUEST_LOCK_WAIT_SECONDS}s'")
        # pg_advisory_lock returns void, which select_value would warn it cannot map.
        connection.execute(SourceImport.sanitize_sql_array([ "SELECT pg_advisory_lock(?)", lock_key ]))
      end
      locked = true
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if locked

      raise Error.new("import_in_progress", "This upload is still being processed. Try again in a moment.")
    ensure
      connection.select_value(SourceImport.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])) if locked
    end
  end
end
