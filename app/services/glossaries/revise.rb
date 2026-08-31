module Glossaries
  class Revise
    class StaleRevisionError < StandardError; end

    def self.call(glossary:, expected_version:, attributes:)
      Glossary.transaction do
        glossary.lock!
        current_version = glossary.current_revision.version
        unless Integer(expected_version, exception: false) == current_version
          raise StaleRevisionError, "This glossary changed while you were editing it. Review the latest revision and try again."
        end

        revision = BuildRevision.call(glossary:, version: current_version + 1, attributes:)
        revision.save!
        glossary.update!(current_revision: revision)
        revision
      end
    end
  end
end
