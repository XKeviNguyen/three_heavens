class AddBackendQueryIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  OWNER_ORDERED_TABLES = %i[
    workflow_profiles glossaries methodology_profiles translation_references
  ].freeze
  PROVIDER_RUN_TABLES = %i[
    translation_runs translation_segment_runs review_runs review_segment_runs
    judge_runs judge_segment_runs finalization_runs finalization_segment_runs
  ].freeze

  def up
    add_index :active_storage_blobs, [ :created_at, :id ], algorithm: :concurrently,
              name: "index_active_storage_blobs_for_cleanup"
    add_index :documents, [ :project_id, :created_at, :id ], order: { created_at: :desc, id: :desc },
              algorithm: :concurrently, name: "index_documents_on_project_and_recent"
    add_index :source_imports, [ :status, :expires_at, :id ], algorithm: :concurrently,
              name: "index_source_imports_for_cleanup"
    add_index :translation_workspace_submissions, [ :status, :expires_at, :id ], algorithm: :concurrently,
              name: "index_workspace_submissions_for_cleanup"

    OWNER_ORDERED_TABLES.each do |table|
      add_index table, [ :user_id, :active, :updated_at, :id ],
                order: { active: :desc, updated_at: :desc, id: :desc },
                algorithm: :concurrently,
                name: "index_#{table}_on_owner_and_recent"
    end

    PROVIDER_RUN_TABLES.each do |table|
      add_index table, [ :completed_at, :id ],
                include: :error_code,
                where: "status = 'failed'",
                algorithm: :concurrently,
                name: "index_#{table}_on_recent_failures"
    end

    remove_index :source_imports, name: "index_source_imports_on_status_and_expires_at",
                                  algorithm: :concurrently, if_exists: true
    OWNER_ORDERED_TABLES.each do |table|
      remove_index table, name: "index_#{table}_on_user_id_and_active",
                    algorithm: :concurrently, if_exists: true
    end
  end

  def down
    add_index :source_imports, [ :status, :expires_at ], algorithm: :concurrently,
              name: "index_source_imports_on_status_and_expires_at", if_not_exists: true
    OWNER_ORDERED_TABLES.each do |table|
      add_index table, [ :user_id, :active ], algorithm: :concurrently,
                name: "index_#{table}_on_user_id_and_active", if_not_exists: true
    end

    remove_index :active_storage_blobs, name: "index_active_storage_blobs_for_cleanup",
                  algorithm: :concurrently, if_exists: true
    remove_index :documents, name: "index_documents_on_project_and_recent",
                 algorithm: :concurrently, if_exists: true
    remove_index :source_imports, name: "index_source_imports_for_cleanup",
                  algorithm: :concurrently, if_exists: true
    remove_index :translation_workspace_submissions,
                 name: "index_workspace_submissions_for_cleanup", algorithm: :concurrently,
                 if_exists: true
    OWNER_ORDERED_TABLES.each do |table|
      remove_index table, name: "index_#{table}_on_owner_and_recent",
                    algorithm: :concurrently, if_exists: true
    end
    PROVIDER_RUN_TABLES.each do |table|
      remove_index table, name: "index_#{table}_on_recent_failures",
                    algorithm: :concurrently, if_exists: true
    end
  end
end
