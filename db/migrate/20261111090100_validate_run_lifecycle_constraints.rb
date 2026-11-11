# Validates the constraints added NOT VALID in 20261111090000. Existing rows
# are checked first so a violation stops the deploy with a message naming the
# table, before any validation scan; no row is changed. VALIDATE CONSTRAINT
# takes SHARE UPDATE EXCLUSIVE, so reads and writes continue during the scan.
class ValidateRunLifecycleConstraints < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
  ].freeze

  def up
    verify_existing_rows!
    execute "SET LOCAL lock_timeout = '10s'"
    validate_check_constraint :translation_runs, name: "translation_runs_status_check"
    validate_check_constraint :experiments, name: "experiments_status_check"
    RUN_TABLES.each { |table| validate_check_constraint table, name: "#{table}_completion_check" }
  end

  def down
    # Validation is not reversible on its own; rolling back the previous
    # migration removes these constraints.
  end

  private

  def verify_existing_rows!
    violations = RUN_TABLES.filter_map do |table|
      count = select_value(<<~SQL.squish).to_i
        SELECT count(*) FROM #{quote_table_name(table)}
        WHERE (status IN ('completed', 'failed')) <> (completed_at IS NOT NULL)
      SQL
      "#{table}: #{count} rows whose completed_at does not match their status" if count.positive?
    end
    %i[translation_runs experiments].each do |table|
      count = select_value(<<~SQL.squish).to_i
        SELECT count(*) FROM #{quote_table_name(table)}
        WHERE status NOT IN ('pending', 'running', 'completed', 'failed')
      SQL
      violations << "#{table}: #{count} rows with an unknown status" if count.positive?
    end
    return if violations.empty?

    raise ActiveRecord::MigrationError,
          "Existing rows violate the run lifecycle constraints; repair them deliberately first: #{violations.join('; ')}"
  end
end
