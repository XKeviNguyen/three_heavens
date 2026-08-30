class AddCostCompletenessToAiRuns < ActiveRecord::Migration[8.1]
  RUN_TABLES = {
    translation_runs: [ :translation_segment_runs, :translation_run_id ],
    review_runs: [ :review_segment_runs, :review_run_id ],
    judge_runs: [ :judge_segment_runs, :judge_run_id ],
    finalization_runs: [ :finalization_segment_runs, :finalization_run_id ]
  }.freeze

  def up
    RUN_TABLES.each_key do |table|
      add_column table, :cost_complete, :boolean, null: false, default: false
    end

    RUN_TABLES.each do |parent_table, (child_table, foreign_key)|
      execute <<~SQL.squish
        UPDATE #{parent_table} AS parent
        SET cost_complete = parent.cost IS NOT NULL AND (
          NOT EXISTS (
            SELECT 1 FROM #{child_table} AS child
            WHERE child.#{foreign_key} = parent.id
          ) OR NOT EXISTS (
            SELECT 1 FROM #{child_table} AS child
            WHERE child.#{foreign_key} = parent.id AND child.cost IS NULL
          )
        )
      SQL
      add_check_constraint parent_table,
                           "NOT cost_complete OR cost IS NOT NULL",
                           name: "#{parent_table}_complete_cost_present_check"
    end
  end

  def down
    RUN_TABLES.each_key do |table|
      remove_check_constraint table, name: "#{table}_complete_cost_present_check"
      remove_column table, :cost_complete
    end
  end
end
