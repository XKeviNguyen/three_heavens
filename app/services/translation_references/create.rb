module TranslationReferences
  class Create
    def self.call(user:, attributes:, active: true)
      TranslationReference.transaction do
        reference = user.translation_references.create!(active: active)
        revision = BuildRevision.call(
          translation_reference: reference,
          version: 1,
          attributes: attributes
        )
        revision.save!
        reference.update!(current_revision: revision)
        reference
      end
    end
  end
end
