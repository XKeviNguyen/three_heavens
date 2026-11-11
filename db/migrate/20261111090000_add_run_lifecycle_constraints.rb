# A provider run's status and its completion time were kept consistent only
# by the services that write them: every path into completed or failed sets
# completed_at, and every path back to pending or running (a retry or a new
# claim) clears it. The database now holds that invariant, and gives
# translation_runs and experiments the allowed-status check that the other
# run tables already have.
#
# Existing rows are checked first: a violation stops the deploy with the
# count per table before any constraint exists, so no row becomes impossible
# to update and no row is changed. The constraints are then added NOT VALID,
# taking only brief locks (experiments before its runs, the order the app
# locks them), and 20261111090100 validates them. Code from before this
# release already writes rows that satisfy them, so an old container running
# during the deploy is unaffected.
class AddRunLifecycleConstraints < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
  ].freeze
  STATUS_TABLES = %i[experiments translation_runs].freeze
  # Written as OR chains: PostgreSQL deparses a varchar IN list differently
  # across dump and reload (test/config/database_schema_format_test.rb).
  STATUSES = "status = 'pending' OR status = 'running' OR status = 'completed' OR status = 'failed'"
  COMPLETION = "(status = 'completed' OR status = 'failed') = (completed_at IS NOT NULL)"

  def up
    verify_existing_rows!
    execute "SET LOCAL lock_timeout = '1s'"
    STATUS_TABLES.each do |table|
      add_check_constraint table, STATUSES, name: "#{table}_status_check", validate: false
    end
    RUN_TABLES.each do |table|
      add_check_constraint table, COMPLETION, name: "#{table}_completion_check", validate: false
    end
  end

  def down
    RUN_TABLES.each { |table| remove_check_constraint table, name: "#{table}_completion_check" }
    STATUS_TABLES.each { |table| remove_check_constraint table, name: "#{table}_status_check" }
  end

  private

  def verify_existing_rows!
    violations = RUN_TABLES.filter_map do |table|
      count = violation_count(table, "NOT (#{COMPLETION})")
      "#{table}: #{count} rows whose completed_at does not match their status" if count.positive?
    end
    STATUS_TABLES.each do |table|
      count = violation_count(table, "NOT (#{STATUSES})")
      violations << "#{table}: #{count} rows with an unknown status" if count.positive?
    end
    return if violations.empty?

    raise ActiveRecord::MigrationError,
          "Existing rows violate the run lifecycle constraints; repair them deliberately first: #{violations.join('; ')}"
  end

  def violation_count(table, condition)
    select_value("SELECT count(*) FROM #{quote_table_name(table)} WHERE #{condition}").to_i
  end
end
