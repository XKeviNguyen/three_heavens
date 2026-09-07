module TranslationReferences
  class ContextBudget
    def self.call(experiment:, model:, stage:, source_character_count:, capability_snapshot:, prompt:, &)
      Ai::ContextBudget.call(
        model: model,
        **prompt,
        stage: stage,
        source_character_count: source_character_count,
        capability_snapshot: capability_snapshot
      )
    rescue Ai::ContextBudget::Error => error
      baseline_prompt = block_given? ? yield : nil
      message = ContextBudgetMessage.for(
        experiment: experiment,
        error: error,
        model: model,
        stage: stage,
        source_character_count: source_character_count,
        capability_snapshot: capability_snapshot,
        prompt_without_references: baseline_prompt
      )
      raise Ai::ContextBudget::Error.new(message, code: error.code)
    end
  end
end
