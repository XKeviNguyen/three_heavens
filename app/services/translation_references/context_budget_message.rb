module TranslationReferences
  module ContextBudgetMessage
    MESSAGE = "The selected references do not fit safely within this model's context window. " \
      "Remove one or more references or choose a model with a larger configured context window."

    module_function

    def for(experiment:, error:, model: nil, stage: nil, source_character_count: nil,
            capability_snapshot: nil, prompt_without_references: nil)
      return error.message unless error.respond_to?(:code) && error.code == "context_budget_exceeded"
      return error.message unless experiment.experiment_reference_revisions.exists? && prompt_without_references

      Ai::ContextBudget.call(
        model: model,
        **prompt_without_references,
        stage: stage,
        source_character_count: source_character_count,
        capability_snapshot: capability_snapshot
      )
      MESSAGE
    rescue Ai::ContextBudget::Error
      error.message
    end
  end
end
