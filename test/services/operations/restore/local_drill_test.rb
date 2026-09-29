require "test_helper"

class Operations::Restore::LocalDrillTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "requires unmistakable explicit intent before creating disposable resources" do
    error = assert_raises(Operations::Restore::LocalDrill::UnsafeDrill) do
      Operations::Restore::LocalDrill.call(environment: {})
    end

    assert_includes error.message, Operations::Restore::LocalDrill::CONFIRMATION_NAME

    error = assert_raises(Operations::Restore::LocalDrill::UnsafeDrill) do
      Operations::Restore::LocalDrill.call(
        environment: {
          Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1",
          "DATABASE_URL" => "postgresql://synthetic-production-marker"
        }
      )
    end
    assert_includes error.message, "production-marked"
  end

  test "loads the SQL schema into a disposable source database" do
    drill = Operations::Restore::LocalDrill.new(
      environment: { Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1" }
    )
    original_configuration = ActiveRecord::Base.connection_db_config.configuration_hash
    original_storage_service = ActiveStorage::Blob.service
    original_storage_services = ActiveStorage::Blob.services
    admin = PG.connect(drill.send(:pg_options, original_configuration, database: "postgres"))
    database = drill.send(:create_database!, admin, "schema")

    Dir.mktmpdir("three-heavens-schema-load-") do |storage_root|
      drill.send(:configure_source!, original_configuration, database, storage_root)

      assert_equal database, ActiveRecord::Base.connection_db_config.database
      assert_equal :sql, ActiveRecord::Base.connection_db_config.schema_format
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'enforce_experiment_glossary_owner_trigger' AND NOT tgisinternal
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_proc
        WHERE proname = 'glossary_revision_configuration_digest'
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'prevent_methodology_profile_revision_mutation_trigger' AND NOT tgisinternal
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'enforce_experiment_methodology_snapshot_trigger' AND NOT tgisinternal
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'enforce_project_methodology_snapshots_trigger' AND NOT tgisinternal
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'enforce_document_methodology_snapshots_trigger' AND NOT tgisinternal
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname = 'enforce_methodology_profile_owner_trigger' AND NOT tgisinternal
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_proc
        WHERE proname = 'methodology_revision_configuration_digest'
      SQL
      assert_equal 1, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_proc
        WHERE proname = 'prevent_parent_lineage_mutation'
      SQL
      assert_equal 8, ActiveRecord::Base.connection.select_value(<<~SQL)
        SELECT count(*) FROM pg_trigger
        WHERE tgname IN (
          'prevent_translation_runs_parent_mutation',
          'prevent_review_runs_parent_mutation',
          'prevent_review_rounds_parent_mutation',
          'prevent_judge_runs_parent_mutation',
          'prevent_judge_rounds_parent_mutation',
          'prevent_finalization_runs_parent_mutation',
          'prevent_finalization_rounds_parent_mutation',
          'prevent_final_translations_parent_mutation'
        ) AND NOT tgisinternal
      SQL
    end
  ensure
    ActiveStorage::Blob.service = original_storage_service if original_storage_service
    ActiveStorage::Blob.services = original_storage_services if original_storage_services
    drill&.send(:restore_application_connection, original_configuration) if original_configuration
    drill&.send(:drop_databases!, admin) if admin
    admin&.close
  end

  test "detects any restored row difference and reads representative data through the application" do
    drill = Operations::Restore::LocalDrill.new(
      environment: { Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1" }
    )
    original_configuration = ActiveRecord::Base.connection_db_config.configuration_hash
    original_storage_service = ActiveStorage::Blob.service
    original_storage_services = ActiveStorage::Blob.services
    admin = PG.connect(drill.send(:pg_options, original_configuration, database: "postgres"))
    source = drill.send(:create_database!, admin, "source")

    Dir.mktmpdir("three-heavens-drill-compare-") do |storage_root|
      drill.send(:configure_source!, original_configuration, source, storage_root)
      expected = drill.send(:create_representative_data!)
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
      copy = "#{Operations::Restore::LocalDrill::DATABASE_PREFIX}copy_#{SecureRandom.hex(8)}"
      admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(copy)} TEMPLATE #{PG::Connection.quote_ident(source)}")
      drill.send(:database_names) << copy
      source_url = drill.send(:connection_string, original_configuration, source)
      copy_url = drill.send(:connection_string, original_configuration, copy)

      assert_operator drill.send(:compare_durable_data!, source_url, copy_url), :>=, 40
      drill.send(:verify_application_reads!, original_configuration, copy, expected)
      ActiveRecord::Base.connection_handler.clear_all_connections!(:all)

      copy_connection = PG.connect(copy_url)
      begin
        copy_connection.exec("DELETE FROM public.federated_identities")
      ensure
        copy_connection.close
      end
      error = assert_raises(Operations::Restore::LocalDrill::UnsafeDrill) do
        drill.send(:compare_durable_data!, source_url, copy_url)
      end
      assert_equal "restored rows differ from the source", error.message
    end
  ensure
    ActiveStorage::Blob.service = original_storage_service if original_storage_service
    ActiveStorage::Blob.services = original_storage_services if original_storage_services
    drill&.send(:restore_application_connection, original_configuration) if original_configuration
    drill&.send(:drop_databases!, admin) if admin
    admin&.close
  end
end
