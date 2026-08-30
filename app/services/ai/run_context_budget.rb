module Ai
  class RunContextBudget
    def self.call(run:, model:, prompt:, stage:, source_character_count:)
      snapshot = {
        "context_window_tokens" => run.context_window_tokens_snapshot,
        "max_output_tokens" => run.max_output_tokens_snapshot
      }
      snapshot = nil unless snapshot.values.all?

      budget = ContextBudget.call(
        model: model,
        **prompt,
        stage: stage,
        source_character_count: source_character_count,
        capability_snapshot: snapshot
      )
      run.update!(budget.snapshot_attributes) unless snapshot
      budget
    end
  end
end
