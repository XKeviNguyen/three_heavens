require "test_helper"
require "timeout"

class ExperimentReferenceConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  DATABASE_PREFIX = "three_heavens_reference_race_"

  %i[association reassignment].each do |first|
    test "snapshot insertion and document reassignment serialize when #{first} locks first" do
      with_disposable_database do |admin, options|
        seed_race_records(PG.connect(options))
        connections = 2.times.map { PG.connect(options) }
        execute_association = Queue.new
        prepared = Queue.new
        execute_update = Queue.new
        commit = Queue.new
        results = Queue.new
        roles = %i[association reassignment]
        threads = roles.map.with_index do |role, index|
          Thread.new do
            connection = connections.fetch(index)
            connection.exec("BEGIN")
            connection.exec("SET LOCAL lock_timeout = '10s'; SET LOCAL statement_timeout = '15s'")
            if role == :reassignment
              if first == :reassignment
                connection.exec("SELECT 1 FROM experiments WHERE id = 1 FOR UPDATE")
                prepared << role
              end
              execute_update.pop
              connection.exec("UPDATE experiments SET document_id = 2 WHERE id = 1")
            else
              execute_association.pop
              connection.exec(<<~SQL)
                INSERT INTO experiment_reference_revisions
                  (experiment_id, translation_reference_revision_id, position, created_at, updated_at)
                VALUES (1, 1, 1, NOW(), NOW())
              SQL
              prepared << role
            end
            commit.pop
            connection.exec("COMMIT")
            results << :committed
          rescue PG::Error => error
            connection.exec("ROLLBACK")
            results << error
          end
        end

        if first == :association
          execute_association << true
          assert_equal :association, Timeout.timeout(20) { prepared.pop }
          execute_update << true
          assert_database_lock_wait!(admin, waiting_pid: connections[1].backend_pid, blocking_pid: connections[0].backend_pid)
        else
          assert_equal :reassignment, Timeout.timeout(20) { prepared.pop }
          execute_association << true
          assert_database_lock_wait!(admin, waiting_pid: connections[0].backend_pid, blocking_pid: connections[1].backend_pid)
          execute_update << true
        end
        commit << true
        threads.each { |thread| assert thread.join(20), "concurrent database mutation did not finish" }
        outcomes = 2.times.map { Timeout.timeout(20) { results.pop } }
        assert_equal 1, outcomes.count(:committed)
        errors = outcomes.grep(PG::Error)
        assert_equal 1, errors.size
        assert_not_kind_of PG::TRDeadlockDetected, errors.sole
        assert_kind_of PG::CheckViolation, errors.sole
        assert_equal "23514", errors.sole.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
        invalid = connections.first.exec(<<~SQL).first.fetch("count").to_i
          SELECT count(*) FROM experiment_reference_revisions snapshots
          JOIN experiments ON experiments.id = snapshots.experiment_id
          JOIN documents ON documents.id = experiments.document_id
          JOIN projects ON projects.id = documents.project_id
          JOIN translation_reference_revisions revisions ON revisions.id = snapshots.translation_reference_revision_id
          JOIN translation_references refs ON refs.id = revisions.translation_reference_id
          WHERE refs.user_id <> projects.user_id
        SQL
        assert_equal 0, invalid
      ensure
        execute_association << true if execute_association
        execute_update << true if execute_update
        2.times { commit << true } if commit
        threads&.each { |thread| thread.join(1) }
        connections&.each(&:close)
      end
    end
  end

  private

  def with_disposable_database
    configuration = ActiveRecord::Base.connection_db_config.configuration_hash
    admin = PG.connect(pg_options(configuration, database: "postgres"))
    database = "#{DATABASE_PREFIX}#{SecureRandom.hex(8)}"
    raise "unsafe concurrency database name" unless database.match?(/\A#{DATABASE_PREFIX}[0-9a-f]{16}\z/)

    admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(database)}")
    database_created = true
    database_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      "test",
      "primary",
      configuration.merge(database: database)
    )
    ActiveRecord::Tasks::DatabaseTasks.load_schema(database_config, :sql)
    yield admin, pg_options(configuration, database:)
  ensure
    if admin && database_created
      admin.exec("DROP DATABASE #{PG::Connection.quote_ident(database)} WITH (FORCE)")
    end
    admin&.close
  end

  def seed_race_records(connection)
    digest = TranslationReferences::ConfigurationDigest.call(TranslationReferenceRevision.new(
      source_language: "Vietnamese", target_language: "Japanese",
      source_text: "Source", approved_translation: "Approved"
    ))
    connection.exec("BEGIN")
    connection.exec(<<~SQL)
      INSERT INTO users (id, email, password_digest, created_at, updated_at) VALUES
        (1, 'owner-one@example.test', 'synthetic', NOW(), NOW()),
        (2, 'owner-two@example.test', 'synthetic', NOW(), NOW());
      INSERT INTO projects (id, user_id, name, source_language, target_language, created_at, updated_at) VALUES
        (1, 1, 'Original', 'Vietnamese', 'Japanese', NOW(), NOW()),
        (2, 2, 'Other owner', 'Vietnamese', 'Japanese', NOW(), NOW());
      INSERT INTO documents (id, project_id, title, source_text, created_at, updated_at) VALUES
        (1, 1, 'Original', 'Source', NOW(), NOW()),
        (2, 2, 'Other', 'Source', NOW(), NOW());
      INSERT INTO translation_references (id, user_id, created_at, updated_at)
        VALUES (1, 1, NOW(), NOW());
      INSERT INTO translation_reference_revisions
        (id, translation_reference_id, version, title, source_language, target_language,
         source_text, approved_translation, configuration_digest, created_at, updated_at)
        VALUES (1, 1, 1, 'Reference', 'Vietnamese', 'Japanese', 'Source', 'Approved',
                #{connection.escape_literal(digest)}, NOW(), NOW());
      UPDATE translation_references SET current_revision_id = 1 WHERE id = 1;
      INSERT INTO experiments (id, document_id, instruction_prompt, created_at, updated_at)
        VALUES (1, 1, 'Translate.', NOW(), NOW());
    SQL
    connection.exec("COMMIT")
  ensure
    connection.exec("ROLLBACK") if connection.transaction_status != PG::PQTRANS_IDLE
    connection.close
  end

  def assert_database_lock_wait!(admin, waiting_pid:, blocking_pid:)
    Timeout.timeout(20) do
      loop do
        activity = admin.exec_params(<<~SQL, [ waiting_pid ]).first
          SELECT wait_event_type, pg_blocking_pids(pid)::text AS blocking_pids
          FROM pg_stat_activity
          WHERE pid = $1
        SQL
        if activity && activity.fetch("wait_event_type") == "Lock" &&
            activity.fetch("blocking_pids").include?(blocking_pid.to_s)
          break
        end

        sleep 0.01
      end
    end
    assert true
  end

  def pg_options(configuration, database:)
    {
      host: configuration[:host],
      port: configuration[:port],
      user: configuration[:username],
      password: configuration[:password],
      dbname: database
    }.compact
  end
end
