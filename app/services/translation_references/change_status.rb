module TranslationReferences
  class ChangeStatus
    def self.activate(translation_reference:)
      translation_reference.update!(active: true)
    end

    def self.deactivate(translation_reference:)
      translation_reference.update!(active: false)
    end
  end
end
