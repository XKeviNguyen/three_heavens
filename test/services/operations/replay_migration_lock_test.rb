require "test_helper"
require_relative "../../support/process_barrier"

class Operations::ReplayMigrationLockTest < ActiveSupport::TestCase
  include ProcessBarrier
  self.use_transactional_tests = false

  test "populated canonical history validates online and metadata locks fail fast" do
    require Rails.root.join("db/migrate/20261005120000_bound_replay_coordination_lifetimes")
    drill = Operations::Restore::LocalDrill.new(environment: { Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1" })
    original = ActiveRecord::Base.connection_db_config.configuration_hash
    storage_service = ActiveStorage::Blob.service
    storage_services = ActiveStorage::Blob.services
    admin = PG.connect(drill.send(:pg_options, original, database: "postgres"))
    database = drill.send(:create_database!, admin, "lock")
    pid = ready_read = ready_write = release_read = release_write = nil
    Dir.mktmpdir("three-heavens-migration-lock-") do |root|
      drill.send(:configure_source!, original, database, root)
      migration = BoundReplayCoordinationLifetimes.new
      migration.migrate(:down)
      user = User.create!(email: "migration-lock@example.test", password: "synthetic test password")
      project = user.projects.create!(name: "Synthetic history", source_language: "Japanese", target_language: "English")
      connection = ActiveRecord::Base.connection
      connection.execute(<<~SQL)
        INSERT INTO documents (project_id, title, source_text, created_at, updated_at)
        SELECT #{project.id}, 'Synthetic history', 'Synthetic', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM generate_series(1, 10000);
        INSERT INTO source_imports (user_id, resulting_document_id, status, original_filename,
          request_key, consumed_at, expires_at, created_at, updated_at)
        SELECT #{user.id}, id, 'consumed', 'synthetic.txt', md5(id::text), CURRENT_TIMESTAMP,
          CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM documents WHERE project_id = #{project.id};
      SQL
      before = connection.select_value("SELECT relfilenode FROM pg_class WHERE oid = 'source_imports'::regclass")

      # A real application write already holds ROW EXCLUSIVE. Metadata DDL
      # must time out safely rather than queue indefinitely behind it.
      with_process_lock("UPDATE source_imports SET request_key = request_key WHERE id = (SELECT min(id) FROM source_imports)") do
        began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(ActiveRecord::LockWaitTimeout) { migration.migrate(:up) }
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - began, :<, 3
        assert_equal "0", connection.select_value("SHOW lock_timeout")
      end
      assert_equal 10000, connection.select_value("SELECT count(*) FROM source_imports WHERE status = 'consumed'")

      ready_read, ready_write = IO.pipe
      release_read, release_write = IO.pipe
      ActiveRecord::Base.connection_handler.clear_all_connections!
      pid = fork do
        ready_read.close
        release_write.close
        probe = BoundReplayCoordinationLifetimes.new
        probe.define_singleton_method(:validate_check_constraint) do |table, **options|
          if table == :source_imports
            transaction do
              super(table, **options)
              ready_write.write("v")
              release_read.read(1)
            end
          else
            super(table, **options)
          end
        end
        probe.migrate(:up)
        exit! 0
      end
      ready_write.close
      release_read.close
      Timeout.timeout(15) { assert_equal "v", ready_read.read(1) }
      connection = ActiveRecord::Base.connection
      locks = connection.select_values("SELECT mode FROM pg_locks WHERE relation = 'source_imports'::regclass AND granted")
      assert_includes locks, "ShareUpdateExclusiveLock"
      assert_not_includes locks, "AccessExclusiveLock"
      connection.transaction do
        connection.execute("SET LOCAL lock_timeout = '100ms'")
        assert_equal 10000, connection.select_value("SELECT count(*) FROM source_imports")
        assert_equal 1, connection.update("UPDATE source_imports SET request_key = request_key WHERE id = (SELECT min(id) FROM source_imports)")
      end
      release_write.write("g")
      Process.wait(pid)
      assert_predicate $?, :success?
      pid = nil
      assert_equal before, connection.select_value("SELECT relfilenode FROM pg_class WHERE oid = 'source_imports'::regclass")
      assert_equal(-1, connection.select_value("SELECT atttypmod FROM pg_attribute WHERE attrelid = 'source_imports'::regclass AND attname = 'request_key'"))
      assert_equal 10000, SourceImport.where(status: :consumed).count
      # Up/down/up must remain available before new signed traffic.
      migration.migrate(:down)
      migration.migrate(:up)
      assert_equal 10000, SourceImport.where(status: :consumed).count
    end
  ensure
    release_write&.write("g") if pid
    Process.wait(pid) if pid
    [ ready_read, ready_write, release_read, release_write ].compact.each { |pipe| pipe.close unless pipe.closed? }
    ActiveStorage::Blob.service = storage_service if storage_service
    ActiveStorage::Blob.services = storage_services if storage_services
    drill&.send(:restore_application_connection, original) if original
    drill&.send(:drop_databases!, admin) if admin
    admin&.close
  end
  test "a timed out reference index build leaves no ledger and reruns safely" do
    require Rails.root.join("db/migrate/20261004170000_add_translation_reference_creation_identity")
    drill = Operations::Restore::LocalDrill.new(environment: { Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1" })
    original = ActiveRecord::Base.connection_db_config.configuration_hash
    admin = PG.connect(drill.send(:pg_options, original, database: "postgres"))
    database = drill.send(:create_database!, admin, "retry")
    ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
    ActiveRecord::Base.establish_connection(original.merge(database:))
    connection = ActiveRecord::Base.connection
    connection.execute(<<~SQL)
      CREATE TABLE users (id bigint PRIMARY KEY);
      CREATE TABLE translation_references (id bigint PRIMARY KEY, user_id bigint NOT NULL);
      INSERT INTO users VALUES (1);
      INSERT INTO translation_references VALUES (1, 1);
    SQL
    migration = AddTranslationReferenceCreationIdentity.new
    with_process_lock("UPDATE translation_references SET user_id = user_id WHERE id = 1") do
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(ActiveRecord::LockWaitTimeout) { migration.migrate(:up) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - began, :<, 3
      assert_not connection.table_exists?(:translation_reference_creations)
      assert_equal false, connection.select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('index_translation_references_on_owner_and_id')")
      assert_equal "0", connection.select_value("SHOW lock_timeout")
    end
    migration.migrate(:up)
    assert connection.table_exists?(:translation_reference_creations)
    assert_equal true, connection.select_value("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass('index_translation_references_on_owner_and_id')")
    migration.migrate(:up)
    migration.migrate(:down)
    migration.migrate(:down)
    migration.migrate(:up)
    assert connection.table_exists?(:translation_reference_creations)
  ensure
    drill&.send(:restore_application_connection, original) if original
    drill&.send(:drop_databases!, admin) if admin
    admin&.close
  end
end
