module TranslationReferences
  class BuildRevision
    def self.call(translation_reference:, version:, attributes:)
      values = attributes.to_h.stringify_keys
      translation_reference.revisions.build(
        version: version,
        title: values.fetch("title", ""),
        source_language: values.fetch("source_language", ""),
        target_language: values.fetch("target_language", ""),
        source_text: values.fetch("source_text", ""),
        approved_translation: values.fetch("approved_translation", "")
      )
    end
  end
end
