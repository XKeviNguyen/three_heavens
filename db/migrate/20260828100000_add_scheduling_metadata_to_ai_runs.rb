class AddSchedulingMetadataToAiRuns < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs
    review_runs
    judge_runs
    finalization_runs
  ].freeze

  def up
    RUN_TABLES.each do |table|
      add_column table, :scheduled_job_id, :string
      add_column table, :claimed_job_execution, :integer, default: 0, null: false
      add_column table, :pending_since, :datetime

      execute <<~SQL.squish
        UPDATE #{quote_table_name(table)}
        SET pending_since = COALESCE(updated_at, created_at)
        WHERE status = 'pending'
      SQL

      add_index table,
                :pending_since,
                name: "index_#{table}_on_pending_since",
                where: "status = 'pending'"
      add_check_constraint table,
                           "claimed_job_execution >= 0",
                           name: "#{table}_claimed_job_execution_check"
    end
  end

  def down
    RUN_TABLES.reverse_each do |table|
      remove_check_constraint table, name: "#{table}_claimed_job_execution_check"
      remove_index table, name: "index_#{table}_on_pending_since"
      remove_column table, :pending_since
      remove_column table, :claimed_job_execution
      remove_column table, :scheduled_job_id
    end
  end
end
