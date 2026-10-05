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
    class RateLimited < Error
      def initialize
        super("rate_limited", "The upload budget is exhausted.")
      end
    end

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
      RequestLock.with(user_id: user.id, request_key:) do
        if SourceImportRetirement.exists?(user_id: user.id, request_key:)
          raise Error.new("import_unavailable", "This upload is no longer available. Upload the file again.")
        end
        existing = user.source_imports.find_by(request_key:)
        next replay(existing, payload) if existing

        receipt = source_import = nil
        SourceImport.transaction(requires_new: true) do
          receipt = UploadBudget.consume(user:)
          raise RateLimited unless receipt

          # Admission and the interrupted-action identity commit together.
          # A worker killed during extraction leaves an unavailable pending
          # import whose replay spends nothing and never starts work again.
          source_import = user.source_imports.create!(import_attributes(payload:, extracted_text: nil, failure: nil).merge(extraction_version: nil))
        end
        begin
          store(source_import, payload)
        rescue Busy
          SourceImport.transaction(requires_new: true) do
            UploadBudget.refund(receipt)
            source_import.destroy!
          end
          raise
        end
      end
    ensure
      upload.rewind if upload.respond_to?(:rewind)
    end

    private

    attr_reader :request_key, :user, :upload

    def store(source_import, payload)
      extracted_text = failure = nil
      begin
        extracted_text = TextExtractor.call(format: payload.detection.format, bytes: payload.bytes)
      rescue Busy
        raise
      rescue Error => error
        failure = error
      end
      source_import = create_import(source_import:, payload:, extracted_text:, failure:)
      failure ||= storage_failure unless source_import.ready?
      raise Error.new(failure.code, failure.message, source_import:) if failure

      source_import
    end

    # Active Storage writes the object after the transaction commits, so the
    # import is committed as pending and becomes ready only once that write
    # has returned. The admitted pending action already exists; any storage
    # failure finalizes it as failed and removes its blob.
    def create_import(source_import:, payload:, extracted_text:, failure:)
      created = source_import
      SourceImport.transaction(requires_new: true) do
        created.update!(import_attributes(payload:, extracted_text:, failure:))
        created.source_file.attach(
          io: StringIO.new(payload.bytes),
          filename: payload.filename,
          content_type: payload.detection.content_type,
          identify: false
        )
      end
      # The availability period starts after durable storage, whose latency is
      # not bounded by the extraction deadline.
      created.update!(status: :ready, expires_at: Limits::IMPORT_EXPIRATION.from_now) unless failure
      created
    rescue StandardError => error
      raise unless created&.id && SourceImport.exists?(created.id)

      Rails.logger.error("source_import_storage_failed source_import_id=#{created.id} error=#{error.class}")
      discard_unstored_object!(SourceImport.find(created.id), failure)
    end

    def discard_unstored_object!(source_import, failure)
      outcome = failure || storage_failure
      blob = source_import.source_file.blob if source_import.source_file.attached?
      SourceImport.transaction(requires_new: true) do
        source_import.source_file.detach if blob
        source_import.update!(
          status: :failed, extracted_text: nil, extraction_version: nil,
          failure_code: outcome.code, failure_message: outcome.message
        )
      end
      ActiveStorageMaintenance::Purge.call(blob:) if blob
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
  end
end
