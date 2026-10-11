# Validates the billing constraints added NOT VALID in 20261010090100.
# VALIDATE CONSTRAINT takes SHARE UPDATE EXCLUSIVE on the checked table (and
# ROW SHARE on open_router_credentials), so reads and writes continue while
# existing rows are scanned. The longer lock timeout lets a conflicting
# autovacuum cancel itself (after deadlock_timeout) instead of failing the deploy.
class ValidateAiBillingIdentity < ActiveRecord::Migration[8.1]
  BILLED_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
    pipeline_runs ai_provider_attempts
  ].freeze

  def up
    execute "SET LOCAL lock_timeout = '10s'"
    validate_check_constraint :users, name: "users_ai_payment_source_check"
    BILLED_TABLES.each do |table|
      validate_foreign_key table, :open_router_credentials
      validate_check_constraint table, name: "#{table}_billing_identity_check"
    end
  end

  def down
    # Validation is not reversible on its own; rolling back the previous
    # migration removes these constraints.
  end
end
