class EnforceParentRunBudgetNumbers < ActiveRecord::Migration[8.1]
  PARENT_RUN_TABLES = %i[
    translation_runs review_runs judge_runs finalization_runs
  ].freeze

  def change
    PARENT_RUN_TABLES.each do |table|
      add_check_constraint table,
                           <<~SQL.squish,
                             estimated_input_tokens IS NULL OR (
                               estimated_input_tokens >= 0 AND
                               reserved_output_tokens > 0 AND
                               context_safety_margin_tokens > 0
                             )
                           SQL
                           name: "#{table}_budget_numbers_check"
    end
  end
end
