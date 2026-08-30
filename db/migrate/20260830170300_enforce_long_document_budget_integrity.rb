class EnforceLongDocumentBudgetIntegrity < ActiveRecord::Migration[8.1]
  PARENT_RUN_TABLES = %i[
    translation_runs review_runs judge_runs finalization_runs
  ].freeze
  SEGMENT_RUN_TABLES = %i[
    translation_segment_runs review_segment_runs judge_segment_runs finalization_segment_runs
  ].freeze

  def change
    add_check_constraint :llm_models,
                         "(context_window_tokens IS NULL) = (max_output_tokens IS NULL)",
                         name: "llm_models_context_capabilities_complete_check"

    PARENT_RUN_TABLES.each do |table|
      add_check_constraint table,
                           parent_budget_constraint,
                           name: "#{table}_budget_snapshot_integrity_check"
    end
    SEGMENT_RUN_TABLES.each do |table|
      add_check_constraint table,
                           complete_budget_constraint,
                           name: "#{table}_budget_snapshot_integrity_check"
    end
  end

  private

  def parent_budget_constraint
    <<~SQL.squish
      (
        context_window_tokens_snapshot IS NULL AND
        max_output_tokens_snapshot IS NULL AND
        estimated_input_tokens IS NULL AND
        reserved_output_tokens IS NULL AND
        context_safety_margin_tokens IS NULL AND
        budget_policy_version IS NULL
      ) OR (
        context_window_tokens_snapshot IS NOT NULL AND
        max_output_tokens_snapshot IS NOT NULL AND
        estimated_input_tokens IS NOT NULL AND
        reserved_output_tokens IS NOT NULL AND
        context_safety_margin_tokens IS NOT NULL AND
        budget_policy_version IS NOT NULL AND
        char_length(budget_policy_version) BETWEEN 1 AND 100 AND
        max_output_tokens_snapshot < context_window_tokens_snapshot AND
        reserved_output_tokens <= max_output_tokens_snapshot AND
        estimated_input_tokens + reserved_output_tokens + context_safety_margin_tokens <= context_window_tokens_snapshot
      )
    SQL
  end

  def complete_budget_constraint
    <<~SQL.squish
      char_length(budget_policy_version) BETWEEN 1 AND 100 AND
      reserved_output_tokens <= max_output_tokens_snapshot AND
      estimated_input_tokens + reserved_output_tokens + context_safety_margin_tokens <= context_window_tokens_snapshot
    SQL
  end
end
