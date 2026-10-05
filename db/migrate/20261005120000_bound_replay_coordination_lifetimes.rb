class BoundReplayCoordinationLifetimes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!
  IDENTITY_SQL = "'^[0-9a-f]{32}$|^[A-Za-z0-9_-]{16,255}--[0-9a-f]{64}\\.[0-9a-f]{32}$'"
  CHECKS = {
    source_imports: [ :request_key, "source_imports_request_key_check" ],
    translation_workspace_drafts: [ :editor_id, "workspace_drafts_editor_id_check" ]
  }.freeze

  def up
    with_short_locks do
      replace_checks(IDENTITY_SQL)
      # Nullable metadata addition has no backfill or heap rewrite. A failed
      # cleanup retains the blob and its bounded retry deadline on that row.
      add_column :active_storage_blobs, :cleanup_retry_at, :datetime unless column_exists?(:active_storage_blobs, :cleanup_retry_at)
      build_index(:active_storage_blobs, "(COALESCE(cleanup_retry_at, created_at + interval '7 days')), id",
        name: "index_active_storage_blobs_on_cleanup_deadline")
      remove_index :active_storage_blobs, name: "index_active_storage_blobs_for_cleanup", algorithm: :concurrently,
        if_exists: true
      build_index(:source_imports, %i[expires_at id], name: "index_source_imports_on_cleanup_deadline",
        where: "status IN ('pending', 'ready', 'failed')")
      remove_index :source_imports, name: "index_source_imports_for_cleanup", algorithm: :concurrently, if_exists: true
    end
  end

  def down
    with_short_locks do
      keys = CHECKS.transform_values(&:first).merge(
        source_import_retirements: :request_key, translation_workspace_draft_editors: :editor_id,
        translation_reference_creations: :creation_key)
      keys.each do |table, key|
        if select_value("SELECT EXISTS (SELECT 1 FROM #{table} WHERE length(#{key}) > 32)")
          raise ActiveRecord::IrreversibleMigration, "Signed identities exist; use a forward correction"
        end
      end
      replace_checks("'^[0-9a-f]{32}$'")
      build_index(:source_imports, %i[status expires_at id], name: "index_source_imports_for_cleanup")
      remove_index :source_imports, name: "index_source_imports_on_cleanup_deadline", algorithm: :concurrently
      add_index :active_storage_blobs, %i[created_at id], name: "index_active_storage_blobs_for_cleanup", algorithm: :concurrently
      remove_index :active_storage_blobs, name: "index_active_storage_blobs_on_cleanup_deadline", algorithm: :concurrently
      remove_column :active_storage_blobs, :cleanup_retry_at
    end
  end

  private

  # Interrupted concurrent builds can leave an INVALID index. Only these
  # migration-owned indexes are repaired, preserving the old serving index
  # until its replacement is valid.
  def build_index(table, columns, name:, **options)
    valid = select_value(<<~SQL)
      SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass(#{connection.quote(name)})
    SQL
    return if valid == true

    remove_index table, name:, algorithm: :concurrently if valid == false
    add_index table, columns, name:, algorithm: :concurrently, **options
  end

  def replace_checks(format)
    CHECKS.each do |table, (key, name)|
      # Swap under a brief metadata lock, without scanning while holding it.
      transaction do
        remove_check_constraint table, name: name
        add_check_constraint table, "#{key} IS NULL OR #{key} ~ #{format}", name:, validate: false
      end
      # This separate validation allows normal reads/writes throughout its scan.
      validate_check_constraint table, name: name
    end
  end

  def with_short_locks
    previous = select_value("SHOW lock_timeout")
    execute "SET lock_timeout = '1s'"
    yield
  ensure
    execute "SET lock_timeout = #{connection.quote(previous)}" if previous
  end
end
