module TranslationReferences
  module ContextBudgetMessage
    MESSAGE = "The selected references do not fit safely within this model's context window. " \
      "Remove one or more references or choose a model with a larger configured context window."

    module_function

    def for(experiment:, error:)
      if error.respond_to?(:code) && error.code == "context_budget_exceeded" &&
          experiment.experiment_reference_revisions.exists?
        MESSAGE
      else
        error.message
      end
    end
  end
end
