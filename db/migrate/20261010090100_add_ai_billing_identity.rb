# Who pays for AI work. users.ai_payment_source is the owner's explicit choice
# for new work. Every provider run, automatic pipeline, and provider attempt
# records the source (and, for a personal key, the exact key version) it was
# authorized under, so later preference or key changes never move existing
# work to another payer. Existing rows ran on the platform key, so 'managed'
# is the correct backfill and keeps current users' behavior unchanged.
#
# This migration only takes brief locks: the columns have constant defaults
# (no rewrite) and the constraints are added NOT VALID. They are validated in
# 20261010090200 and indexed concurrently in 20261010090300.
#
# Two fences keep code from before this release (an old container during the
# deploy, or a rolled-back image) from paying for personal-key work with the
# platform key:
# - The run tables keep no billing_source default after the backfill, so an
#   insert that does not name its payer fails. Old code creating any AI run
#   (for example an automatic pipeline advancing a personal-key workflow)
#   fails closed; this code supplies the payer (Ai::BillingIdentity).
# - The trigger makes every provider attempt carry its run's recorded payer.
#   An old worker claiming personal-key work records a 'managed' attempt,
#   which is refused before any provider request is sent. It also keeps
#   cost attribution honest permanently.
class AddAiBillingIdentity < ActiveRecord::Migration[8.1]
  RUN_TABLES = {
    "TranslationRun" => "translation_runs",
    "TranslationSegmentRun" => "translation_segment_runs",
    "ReviewRun" => "review_runs",
    "ReviewSegmentRun" => "review_segment_runs",
    "JudgeRun" => "judge_runs",
    "JudgeSegmentRun" => "judge_segment_runs",
    "FinalizationRun" => "finalization_runs",
    "FinalizationSegmentRun" => "finalization_segment_runs"
  }.freeze
  BILLED_TABLES = (RUN_TABLES.values + %w[pipeline_runs ai_provider_attempts]).map(&:to_sym).freeze

  def up
    execute "SET LOCAL lock_timeout = '1s'"
    add_column :users, :ai_payment_source, :string, null: false, default: "managed"
    add_check_constraint :users, "ai_payment_source = 'managed' OR ai_payment_source = 'personal'",
      name: "users_ai_payment_source_check", validate: false

    BILLED_TABLES.each do |table|
      add_column table, :billing_source, :string, null: false, default: "managed"
      add_column table, :open_router_credential_id, :bigint
      add_foreign_key table, :open_router_credentials, validate: false
      add_check_constraint table,
        "(billing_source = 'managed' AND open_router_credential_id IS NULL) OR " \
        "(billing_source = 'personal' AND open_router_credential_id IS NOT NULL)",
        name: "#{table}_billing_identity_check", validate: false
    end
    RUN_TABLES.each_value { |table| change_column_default table, :billing_source, from: "managed", to: nil }

    run_table_cases = RUN_TABLES.map { |type, table| "WHEN '#{type}' THEN '#{table}'" }.join(" ")
    execute <<~SQL
      CREATE FUNCTION enforce_provider_attempt_payer() RETURNS trigger
          LANGUAGE plpgsql
          AS $$
      DECLARE
        run_billing_source character varying;
        run_credential_id bigint;
      BEGIN
        IF TG_OP = 'UPDATE' THEN
          IF OLD.billing_source IS DISTINCT FROM NEW.billing_source OR
             OLD.open_router_credential_id IS DISTINCT FROM NEW.open_router_credential_id THEN
            RAISE EXCEPTION 'Provider attempt payers are immutable';
          END IF;
          RETURN NEW;
        END IF;

        EXECUTE format(
          'SELECT billing_source, open_router_credential_id FROM %I WHERE id = $1',
          CASE NEW.provider_run_type #{run_table_cases} END
        ) INTO run_billing_source, run_credential_id USING NEW.provider_run_id;
        IF run_billing_source IS NULL OR
           NEW.billing_source IS DISTINCT FROM run_billing_source OR
           NEW.open_router_credential_id IS DISTINCT FROM run_credential_id THEN
          RAISE EXCEPTION 'Provider attempt payer must match its run authorization';
        END IF;
        RETURN NEW;
      END;
      $$;
    SQL
    # Named to fire after enforce_ai_provider_attempt_lineage (triggers on one
    # event fire alphabetically), so lineage errors are reported first.
    execute <<~SQL
      CREATE TRIGGER enforce_ai_provider_attempt_payer BEFORE INSERT OR UPDATE ON ai_provider_attempts
      FOR EACH ROW EXECUTE FUNCTION enforce_provider_attempt_payer();
    SQL
  end

  def down
    execute "SET LOCAL lock_timeout = '1s'"
    execute "DROP TRIGGER enforce_ai_provider_attempt_payer ON ai_provider_attempts"
    execute "DROP FUNCTION enforce_provider_attempt_payer()"
    BILLED_TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_billing_identity_check"
      remove_column table, :open_router_credential_id
      remove_column table, :billing_source
    end
    remove_check_constraint :users, name: "users_ai_payment_source_check"
    remove_column :users, :ai_payment_source
  end
end
