module Glossaries
  class Create
    def self.call(user:, attributes:, active: true)
      Glossary.transaction do
        glossary = user.glossaries.create!(active: active)
        revision = BuildRevision.call(glossary:, version: 1, attributes:)
        revision.save!
        glossary.update!(current_revision: revision)
        glossary
      end
    end
  end
end
