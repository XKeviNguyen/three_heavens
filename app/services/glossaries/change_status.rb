module Glossaries
  class ChangeStatus
    def self.activate(glossary:)
      glossary.update!(active: true)
    end

    def self.deactivate(glossary:)
      glossary.update!(active: false)
    end
  end
end
