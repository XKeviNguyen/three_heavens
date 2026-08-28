class AddExecutionTrackingToAiRuns < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs
    review_runs
    judge_runs
    finalization_runs
  ].freeze

  def up
    RUN_TABLES.each do |table|
      add_column table, :last_claimed_at, :datetime
      add_column table, :execution_attempt, :integer, default: 0, null: false

      execute <<~SQL.squish
        UPDATE #{quote_table_name(table)}
        SET last_claimed_at = COALESCE(started_at, updated_at)
        WHERE status = 'running'
      SQL

      add_index table,
                :last_claimed_at,
                name: "index_#{table}_on_running_last_claimed_at",
                where: "status = 'running'"
      add_check_constraint table,
                           "execution_attempt >= 0",
                           name: "#{table}_execution_attempt_check"
    end
  end

  def down
    RUN_TABLES.reverse_each do |table|
      remove_check_constraint table, name: "#{table}_execution_attempt_check"
      remove_index table, name: "index_#{table}_on_running_last_claimed_at"
      remove_column table, :execution_attempt
      remove_column table, :last_claimed_at
    end
  end
end
