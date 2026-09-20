module TranslationReferences
  class Revise
    class StaleRevisionError < StandardError; end

    def self.call(translation_reference:, expected_version:, attributes:)
      TranslationReference.transaction do
        translation_reference.lock!
        current_version = translation_reference.current_revision.version
        unless Integer(expected_version, exception: false) == current_version
          raise StaleRevisionError,
                "This reference changed while you were editing it. Review the latest revision and try again."
        end

        revision = BuildRevision.call(
          translation_reference: translation_reference,
          version: current_version + 1,
          attributes: attributes
        )
        revision.save!
        translation_reference.update!(current_revision: revision)
        revision
      end
    end
  end
end
