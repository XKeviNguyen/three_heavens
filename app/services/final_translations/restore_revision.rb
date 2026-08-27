module FinalTranslations
  class RestoreRevision
    def self.call(final_translation:, version_id:, expected_version_number:)
      new(
        final_translation: final_translation,
        version_id: version_id,
        expected_version_number: expected_version_number
      ).call
    end

    def initialize(final_translation:, version_id:, expected_version_number:)
      @final_translation = final_translation
      @version_id = version_id
      @expected_version_number = Integer(expected_version_number, exception: false)
    end

    def call
      raise StaleVersionError, "Expected version is invalid" unless expected_version_number&.positive?

      FinalTranslation.transaction do
        final_translation.lock!
        raise InvalidStateError, "Reopen the final translation before restoring a revision" unless final_translation.draft?

        source = final_translation.versions.find(version_id)
        current = final_translation.current_version
        return current if current.content == source.content

        unless current.version_number == expected_version_number
          raise StaleVersionError, "The draft changed before this revision could be restored"
        end

        restored = final_translation.versions.create!(
          version_number: final_translation.versions.maximum(:version_number).to_i + 1,
          content: source.content,
          origin: :restored,
          change_note: "Restored from version #{source.version_number}"
        )
        final_translation.update!(current_version: restored)
        restored
      end
    end

    private

    attr_reader :expected_version_number, :final_translation, :version_id
  end
end
