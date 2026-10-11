# Indexes the credential references added in 20261010090100 without
# blocking writes. Safe to run again after a partial failure: valid indexes
# are kept and an INVALID one left by a failed concurrent build is rebuilt.
class IndexAiBillingCredentials < ActiveRecord::Migration[8.1]
  BILLED_TABLES = %i[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
    pipeline_runs ai_provider_attempts
  ].freeze

  disable_ddl_transaction!

  def up
    BILLED_TABLES.each do |table|
      name = index_name(table, :open_router_credential_id)
      valid = select_value(<<~SQL)
        SELECT pg_index.indisvalid FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indexrelid
        WHERE pg_class.relname = #{connection.quote(name)} AND pg_class.relnamespace = 'public'::regnamespace
      SQL
      next if valid == true

      execute "DROP INDEX CONCURRENTLY IF EXISTS #{connection.quote_table_name(name)}" if valid == false
      add_index table, :open_router_credential_id, where: "open_router_credential_id IS NOT NULL",
        algorithm: :concurrently
    end
  end

  def down
    BILLED_TABLES.each do |table|
      remove_index table, :open_router_credential_id, algorithm: :concurrently
    end
  end
end
