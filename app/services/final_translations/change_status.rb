module FinalTranslations
  class ChangeStatus
    def self.finalize(final_translation:)
      new(final_translation).finalize
    end

    def self.reopen(final_translation:)
      new(final_translation).reopen
    end

    def initialize(final_translation)
      @final_translation = final_translation
    end

    def finalize
      final_translation.with_lock do
        return final_translation if final_translation.finalized?
        if final_translation.current_version&.content.blank?
          raise InvalidStateError, "A nonblank current version is required"
        end

        final_translation.update!(status: :finalized, finalized_at: Time.current)
      end
      final_translation
    end

    def reopen
      final_translation.with_lock do
        return final_translation if final_translation.draft?

        final_translation.update!(status: :draft, finalized_at: nil)
      end
      final_translation
    end

    private

    attr_reader :final_translation
  end
end
