# Who pays for AI work. users.ai_payment_source is the owner's explicit choice
# for new work. Every provider run, automatic pipeline, and provider attempt
# records the source (and, for a personal key, the exact key version) it was
# authorized under, so later preference or key changes never move existing
# work to another payer. Existing rows ran on the platform key, so 'managed'
# is the correct backfill and keeps current users' behavior unchanged.
class AddAiBillingIdentity < ActiveRecord::Migration[8.1]
  BILLED_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
    pipeline_runs ai_provider_attempts
  ].freeze

  def up
    execute "SET LOCAL lock_timeout = '1s'"
    add_column :users, :ai_payment_source, :string, null: false, default: "managed"
    add_check_constraint :users, "ai_payment_source = 'managed' OR ai_payment_source = 'personal'",
      name: "users_ai_payment_source_check"

    BILLED_TABLES.each do |table|
      add_column table, :billing_source, :string, null: false, default: "managed"
      add_column table, :open_router_credential_id, :bigint
      add_foreign_key table, :open_router_credentials
      add_index table, :open_router_credential_id, where: "open_router_credential_id IS NOT NULL"
      add_check_constraint table,
        "(billing_source = 'managed' AND open_router_credential_id IS NULL) OR " \
        "(billing_source = 'personal' AND open_router_credential_id IS NOT NULL)",
        name: "#{table}_billing_identity_check"
    end
  end

  def down
    execute "SET LOCAL lock_timeout = '1s'"
    BILLED_TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_billing_identity_check"
      remove_column table, :open_router_credential_id
      remove_column table, :billing_source
    end
    remove_check_constraint :users, name: "users_ai_payment_source_check"
    remove_column :users, :ai_payment_source
  end
end
