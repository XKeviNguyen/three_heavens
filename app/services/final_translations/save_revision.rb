module FinalTranslations
  class SaveRevision
    def self.call(final_translation:, content:, expected_version_number:, change_note: nil)
      new(
        final_translation: final_translation,
        content: content,
        expected_version_number: expected_version_number,
        change_note: change_note
      ).call
    end

    def initialize(final_translation:, content:, expected_version_number:, change_note: nil)
      @final_translation = final_translation
      @content = content.to_s
      @expected_version_number = Integer(expected_version_number, exception: false)
      @change_note = change_note.presence
    end

    def call
      validate_input!

      FinalTranslation.transaction do
        final_translation.lock!
        validate_draft!
        current = final_translation.current_version
        return current if current.content == content

        validate_expected_version!(current)
        version = final_translation.versions.create!(
          version_number: next_version_number,
          content: content,
          origin: :manual,
          segment_alignment_valid: final_translation.experiment.document_execution_plan.nil?,
          change_note: change_note
        )
        final_translation.update!(current_version: version)
        version
      end
    end

    private

    attr_reader :change_note, :content, :expected_version_number, :final_translation

    def validate_input!
      if content.blank?
        raise InvalidStateError, "Final translation content cannot be blank"
      end
      if content.length > FinalTranslationVersion::MAX_CONTENT_LENGTH
        raise InvalidStateError, "Final translation content is too long"
      end
      if change_note && change_note.length > FinalTranslationVersion::MAX_CHANGE_NOTE_LENGTH
        raise InvalidStateError, "Change note is too long"
      end
      raise StaleVersionError, "Expected version is invalid" unless expected_version_number&.positive?
    end

    def validate_draft!
      return if final_translation.draft?

      raise InvalidStateError, "Reopen the final translation before editing it"
    end

    def validate_expected_version!(current)
      return if current.version_number == expected_version_number

      raise StaleVersionError,
            "This draft changed after the page was loaded. Reconcile your text with the current version."
    end

    def next_version_number
      final_translation.versions.maximum(:version_number).to_i + 1
    end
  end
end
