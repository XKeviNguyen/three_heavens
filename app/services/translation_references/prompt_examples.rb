module TranslationReferences
  class PromptExamples
    def self.call(experiment)
      experiment.experiment_reference_revisions
        .includes(:translation_reference_revision)
        .order(:position)
        .map(&:translation_reference_revision).map do |revision|
        {
          source_text: revision.source_text,
          approved_translation: revision.approved_translation
        }
      end
    end
  end
end
