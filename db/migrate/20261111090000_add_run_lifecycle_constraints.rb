# A provider run's status and its completion time were kept consistent only
# by the services that write them: every path into completed or failed sets
# completed_at, and every path back to pending or running (a retry or a new
# claim) clears it. The database now holds that invariant, and gives
# translation_runs and experiments the allowed-status check that the other
# run tables already have.
#
# Constraints are added NOT VALID, so this migration takes only brief locks;
# 20261111090100 checks existing rows and validates them. Code from before
# this release already writes rows that satisfy them, so an old container
# running during the deploy is unaffected.
class AddRunLifecycleConstraints < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
  ].freeze
  # Written as OR chains: PostgreSQL deparses a varchar IN list differently
  # across dump and reload (test/config/database_schema_format_test.rb).
  STATUSES = "status = 'pending' OR status = 'running' OR status = 'completed' OR status = 'failed'"
  COMPLETION = "(status = 'completed' OR status = 'failed') = (completed_at IS NOT NULL)"

  def up
    execute "SET LOCAL lock_timeout = '1s'"
    add_check_constraint :translation_runs, STATUSES, name: "translation_runs_status_check", validate: false
    add_check_constraint :experiments, STATUSES, name: "experiments_status_check", validate: false
    RUN_TABLES.each do |table|
      add_check_constraint table, COMPLETION, name: "#{table}_completion_check", validate: false
    end
  end

  def down
    RUN_TABLES.each { |table| remove_check_constraint table, name: "#{table}_completion_check" }
    remove_check_constraint :experiments, name: "experiments_status_check"
    remove_check_constraint :translation_runs, name: "translation_runs_status_check"
  end
end
