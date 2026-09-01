module MethodologyProfiles
  class BuildRevision
    def self.call(methodology_profile:, version:, attributes:)
      values = attributes.to_h.stringify_keys
      methodology_profile.revisions.build(
        version: version,
        name: values.fetch("name", ""),
        description: values["description"],
        source_language: values.fetch("source_language", ""),
        target_language: values.fetch("target_language", ""),
        guidance: values.fetch("guidance", "")
      )
    end
  end
end
