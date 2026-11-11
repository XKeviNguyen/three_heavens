# Validates the constraints added NOT VALID in 20261111090000, which checked
# existing rows before adding them. VALIDATE CONSTRAINT takes SHARE UPDATE
# EXCLUSIVE, so reads and writes continue during the scan.
class ValidateRunLifecycleConstraints < ActiveRecord::Migration[8.1]
  RUN_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
  ].freeze

  def up
    execute "SET LOCAL lock_timeout = '10s'"
    validate_check_constraint :experiments, name: "experiments_status_check"
    validate_check_constraint :translation_runs, name: "translation_runs_status_check"
    RUN_TABLES.each { |table| validate_check_constraint table, name: "#{table}_completion_check" }
  end

  def down
    # Validation is not reversible on its own; rolling back the previous
    # migration removes these constraints.
  end
end
