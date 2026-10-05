require "digest"

module TranslationReferences
  class Create
    class KeyReused < AuthoringAttributes::Error; end
    class InProgress < AuthoringAttributes::Error; end
    class Interrupted < AuthoringAttributes::Error; end

    def self.call(user:, attributes:, active: true, creation_key: ReplayIdentity.issue)
      new(user:, attributes:, active:, creation_key:).call
    end

    def initialize(user:, attributes:, active:, creation_key:)
      @user, @attributes, @active, @creation_key = user, attributes.to_h.stringify_keys, active, creation_key
    end

    def call
      unless creation_key.is_a?(String) && creation_key.match?(SourceImports::Limits::REQUEST_KEY_FORMAT)
        raise ArgumentError, "invalid reference creation key"
      end

      digest = payload_digest
      with_request_lock do
        existing = TranslationReferenceCreation.find_by(user:, creation_key:)
        unless ReplayIdentity.valid?(creation_key, existing:)
          raise Interrupted, "This reference action has expired. Start a new submission."
        end
        next replay(existing, digest) if existing
        raise Interrupted, "This reference action is invalid. Start a new submission." unless ReplayIdentity.complete?(creation_key)

        receipt = action = nil
        TranslationReferenceCreation.transaction(requires_new: true) do
          ReplayIdentity.admit!(ledger: TranslationReferenceCreation, user:, identity: { creation_key: })
          receipt = UploadBudget.consume(user:) if uploading_files?
          raise SourceImports::Create::RateLimited if uploading_files? && !receipt

          # Commit the action together with its charge before any extraction.
          # Process loss leaves a pending tombstone, never another admission.
          action = TranslationReferenceCreation.create!(user:, creation_key:, payload_digest: digest,
            expires_at: [ ReplayIdentity.expires_at(creation_key), TranslationReferenceCreation::FAILURE_RETENTION.from_now ].max)
        end
        perform(action, receipt)
      end
    rescue ReplayIdentity::AdmissionExceeded
      raise Interrupted, "Too many recent reference submissions. Try again later."
    end

    private

    attr_reader :user, :attributes, :active, :creation_key

    def perform(action, receipt)
      resolved = AuthoringAttributes.call(attributes)
      TranslationReference.transaction(requires_new: true) do
        reference = user.translation_references.create!(active:)
        revision = BuildRevision.call(translation_reference: reference, version: 1, attributes: resolved)
        revision.save!
        reference.update!(current_revision: revision)
        action.update!(status: :completed, translation_reference: reference)
        reference
      end
    rescue AuthoringAttributes::Busy => error
      if error.work_consumed
        record_failure(action, error, busy: true)
      else
        TranslationReferenceCreation.transaction(requires_new: true) do
          UploadBudget.refund(receipt)
          action.destroy!
        end
      end
      raise
    rescue AuthoringAttributes::Error => error
      record_failure(action, error)
      raise
    rescue ActiveRecord::RecordInvalid => error
      failure = AuthoringAttributes::Error.new(error.record.errors.full_messages.join(" "), resolved_attributes: resolved || {})
      record_failure(action, failure)
      raise failure
    end

    def record_failure(action, error, busy: false)
      action.update!(status: :failed, failure: JSON.generate({
        busy:, message: error.message, code: (error.code if busy), resolved_attributes: bounded_recovery(error.resolved_attributes)
      }))
    end

    def bounded_recovery(values)
      TranslationReferenceCreation::RECOVERY_FIELD_LIMITS.each_with_object({}) do |(field, limit), recovery|
        value = values[field]
        recovery[field] = value if value.is_a?(String) && value.length <= limit && value.bytesize <= limit * 4
      end
    end

    def replay(action, digest)
      raise KeyReused, "This reference action was already submitted with different content." unless action.payload_digest == digest
      return action.translation_reference if action.completed?
      raise Interrupted, "This reference action was interrupted. Start a new submission." if action.pending?

      if action.expired? || action.recovery_expired?
        action.update!(status: :expired, failure: nil) unless action.expired?
        raise Interrupted, "This reference action has expired. Start a new submission."
      end
      failure = JSON.parse(action.failure)
      if failure.fetch("busy")
        error = SourceImports::Busy.new(failure.fetch("code"), failure.fetch("message"))
        raise AuthoringAttributes::Busy.new(error, resolved_attributes: failure.fetch("resolved_attributes"), work_consumed: true)
      end
      raise AuthoringAttributes::Error.new(failure.fetch("message"), resolved_attributes: failure.fetch("resolved_attributes"))
    end

    def with_request_lock
      connection = TranslationReferenceCreation.connection
      lock_key = TranslationReferenceCreation.lock_key(user_id: user.id, creation_key:)
      TranslationReferenceCreation.transaction(requires_new: true) do
        connection.execute("SET LOCAL lock_timeout = '#{SourceImports::Limits::REQUEST_LOCK_WAIT_SECONDS}s'")
        connection.execute(TranslationReferenceCreation.sanitize_sql_array([ "SELECT pg_advisory_lock(?)", lock_key ]))
      end
      locked = true
      yield
    rescue ActiveRecord::LockWaitTimeout
      raise if locked

      raise InProgress, "This reference is still being saved. Retry the same submission."
    ensure
      connection.select_value(TranslationReferenceCreation.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])) if locked
    end

    def uploading_files?
      AuthoringAttributes::SIDES.values.any? { |key| attributes[key].present? }
    end

    # Hash the submitted action, not its extracted text or latest revision.
    # Replays never extract again, even after the reference has been revised.
    def payload_digest
      values = attributes.slice("title", "source_language", "target_language", *AuthoringAttributes::SIDES.keys).sort.to_h
      AuthoringAttributes::SIDES.values.each do |key|
        upload = attributes[key]
        next unless upload.present?

        begin
          upload.rewind
          bytes = upload.read(SourceImports::Limits::MAX_UPLOAD_BYTES + 1)
          values[key] = [ upload.original_filename, upload.content_type, Digest::SHA256.hexdigest(bytes) ]
        ensure
          upload.rewind
        end
      end
      Digest::SHA256.hexdigest(JSON.generate([ active, values ]))
    end
  end
end
