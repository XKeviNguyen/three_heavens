require "test_helper"
require "timeout"

class ExperimentMethodologyConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  DATABASE_PREFIX = "three_heavens_methodology_race_"

  test "concurrent methodology association and project ownership change serialize without deadlock" do
    with_disposable_database do |admin, options|
      seed = seed_race_records(PG.connect(options))
      connections = 2.times.map { PG.connect(options) }
      roles = %i[association ownership]
      events = Queue.new
      start_gate = Queue.new
      execution_gate = Queue.new
      commit_gate = Queue.new
      results = Queue.new
      threads = roles.each_with_index.map do |role, index|
        Thread.new do
          run_mutation(
            connection: connections.fetch(index),
            role:,
            seed:,
            events:,
            start_gate:,
            execution_gate:,
            commit_gate:,
            results:
          )
        end
      end

      ready = 2.times.to_h do
        event, role, pid = Timeout.timeout(20) { events.pop }
        assert_equal :ready, event
        [ role, pid ]
      end
      assert_equal 2, ready.values.uniq.size
      2.times { start_gate << true }
      2.times do
        event, = Timeout.timeout(20) { events.pop }
        assert_equal :prepared, event
      end
      2.times { execution_gate << true }

      event, winner = Timeout.timeout(20) { events.pop }
      assert_equal :updated, event
      loser = (roles - [ winner ]).sole
      assert_database_lock_wait!(admin, waiting_pid: ready.fetch(loser), blocking_pid: ready.fetch(winner))
      commit_gate << true

      threads.each { |thread| assert thread.join(20), "concurrent database mutation did not finish" }
      outcomes = 2.times.map { Timeout.timeout(20) { results.pop } }
      committed = outcomes.select { |outcome| outcome.fetch(:status) == :committed }
      rejected = outcomes.select { |outcome| outcome.fetch(:status) == :rejected }

      assert_equal 1, committed.size
      assert_equal 1, rejected.size
      error = rejected.sole.fetch(:error)
      assert_kind_of PG::CheckViolation, error
      assert_not_kind_of PG::TRDeadlockDetected, error
      assert_equal "23514", error.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      assert_equal winner, committed.sole.fetch(:role)
      assert_valid_final_ownership!(PG.connect(options), seed:)
    ensure
      2.times { start_gate << true } if start_gate
      2.times { execution_gate << true } if execution_gate
      2.times { commit_gate << true } if commit_gate
      threads&.each { |thread| thread.join(1) }
      connections&.each(&:close)
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
    digest = Digest::SHA256.hexdigest(
      JSON.generate(
        "source_language" => "Vietnamese",
        "target_language" => "Japanese",
        "guidance" => "Preserve theological nuance."
      )
    )
    connection.exec("BEGIN")
    connection.exec(<<~SQL)
      INSERT INTO users (id, email, password_digest, created_at, updated_at) VALUES
        (1, 'owner-one@example.test', 'synthetic', NOW(), NOW()),
        (2, 'owner-two@example.test', 'synthetic', NOW(), NOW());
      INSERT INTO projects (
        id, user_id, name, source_language, target_language, created_at, updated_at
      ) VALUES (1, 1, 'Race project', 'Vietnamese', 'Japanese', NOW(), NOW());
      INSERT INTO documents (id, project_id, title, source_text, created_at, updated_at)
      VALUES (1, 1, 'Race source', 'Source', NOW(), NOW());
      INSERT INTO methodology_profiles (id, user_id, created_at, updated_at)
      VALUES (1, 1, NOW(), NOW());
      INSERT INTO methodology_profile_revisions (
        id, methodology_profile_id, version, name, source_language, target_language,
        guidance, configuration_digest, created_at, updated_at
      ) VALUES (
        1, 1, 1, 'Race methodology', 'Vietnamese', 'Japanese',
        'Preserve theological nuance.', #{connection.escape_literal(digest)}, NOW(), NOW()
      );
      UPDATE methodology_profiles SET current_revision_id = 1 WHERE id = 1;
    SQL
    connection.exec("COMMIT")
    { experiment_id: 1, methodology_revision_id: 1, project_id: 1, new_owner_id: 2 }
  ensure
    connection.exec("ROLLBACK") if connection.transaction_status != PG::PQTRANS_IDLE
    connection.close
  end

  def run_mutation(connection:, role:, seed:, events:, start_gate:, execution_gate:, commit_gate:, results:)
    connection.exec("BEGIN")
    connection.exec("SET LOCAL lock_timeout = '30s'; SET LOCAL statement_timeout = '40s'")
    events << [ :ready, role, connection.backend_pid ]
    start_gate.pop
    events << [ :prepared, role ]
    execution_gate.pop
    if role == :association
      connection.exec_params(
        <<~SQL,
          INSERT INTO experiments (
            id, document_id, instruction_prompt, methodology_profile_revision_id, created_at, updated_at
          ) VALUES ($1, 1, 'Translate faithfully.', $2, NOW(), NOW())
        SQL
        [ seed.fetch(:experiment_id), seed.fetch(:methodology_revision_id) ]
      )
    else
      connection.exec_params(
        "UPDATE projects SET user_id = $1, updated_at = NOW() WHERE id = $2",
        [ seed.fetch(:new_owner_id), seed.fetch(:project_id) ]
      )
    end
    events << [ :updated, role ]
    commit_gate.pop
    connection.exec("COMMIT")
    results << { role:, status: :committed }
  rescue PG::Error => error
    connection.exec("ROLLBACK") if connection.transaction_status != PG::PQTRANS_IDLE
    results << { role:, status: :rejected, error: }
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

  def assert_valid_final_ownership!(connection, seed:)
    row = connection.exec_params(<<~SQL, [ seed.fetch(:experiment_id) ]).first
      SELECT experiments.methodology_profile_revision_id, projects.user_id AS project_owner_id,
             methodology_profiles.user_id AS methodology_owner_id
      FROM experiments
      INNER JOIN documents ON documents.id = experiments.document_id
      INNER JOIN projects ON projects.id = documents.project_id
      LEFT JOIN methodology_profile_revisions
        ON methodology_profile_revisions.id = experiments.methodology_profile_revision_id
      LEFT JOIN methodology_profiles
        ON methodology_profiles.id = methodology_profile_revisions.methodology_profile_id
      WHERE experiments.id = $1
    SQL

    if row
      assert_equal seed.fetch(:methodology_revision_id).to_s, row.fetch("methodology_profile_revision_id")
      assert_equal row.fetch("project_owner_id"), row.fetch("methodology_owner_id")
    else
      project_owner_id = connection.exec_params(
        "SELECT user_id FROM projects WHERE id = $1",
        [ seed.fetch(:project_id) ]
      ).first.fetch("user_id")
      assert_equal seed.fetch(:new_owner_id).to_s, project_owner_id
    end
  ensure
    connection&.close
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
