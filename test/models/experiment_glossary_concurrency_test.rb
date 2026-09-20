require "test_helper"
require "timeout"

class ExperimentGlossaryConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  DATABASE_PREFIX = "three_heavens_glossary_race_"

  test "concurrent glossary reassignment is rejected while project ownership change serializes" do
    with_disposable_database do |_admin, options|
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
      assert_equal :ownership, winner
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
        "entries" => [ {
          "position" => 1,
          "source_term" => "Sabbath",
          "preferred_target_term" => "安息日",
          "note" => nil
        } ]
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
      VALUES (1, 1, 'Race source', 'Sabbath', NOW(), NOW());
      INSERT INTO glossaries (id, user_id, created_at, updated_at)
      VALUES (1, 1, NOW(), NOW());
      INSERT INTO glossary_revisions (
        id, glossary_id, version, name, source_language, target_language,
        configuration_digest, entry_set_sealed, created_at, updated_at
      ) VALUES (
        1, 1, 1, 'Race glossary', 'Vietnamese', 'Japanese',
        #{connection.escape_literal(digest)}, FALSE, NOW(), NOW()
      );
      INSERT INTO glossary_entries (
        id, glossary_revision_id, position, source_term, preferred_target_term, created_at, updated_at
      ) VALUES (1, 1, 1, 'Sabbath', '安息日', NOW(), NOW());
      SET CONSTRAINTS seal_glossary_revision_entry_set_trigger IMMEDIATE;
      UPDATE glossaries SET current_revision_id = 1 WHERE id = 1;
      INSERT INTO experiments (id, document_id, instruction_prompt, created_at, updated_at)
      VALUES (1, 1, 'Translate faithfully.', NOW(), NOW());
    SQL
    connection.exec("COMMIT")
    { experiment_id: 1, glossary_revision_id: 1, project_id: 1, new_owner_id: 2 }
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
        "UPDATE experiments SET glossary_revision_id = $1, updated_at = NOW() WHERE id = $2",
        [ seed.fetch(:glossary_revision_id), seed.fetch(:experiment_id) ]
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

  def assert_valid_final_ownership!(connection, seed:)
    row = connection.exec_params(<<~SQL, [ seed.fetch(:experiment_id) ]).first
      SELECT experiments.glossary_revision_id, projects.user_id AS project_owner_id,
             glossaries.user_id AS glossary_owner_id
      FROM experiments
      INNER JOIN documents ON documents.id = experiments.document_id
      INNER JOIN projects ON projects.id = documents.project_id
      LEFT JOIN glossary_revisions ON glossary_revisions.id = experiments.glossary_revision_id
      LEFT JOIN glossaries ON glossaries.id = glossary_revisions.glossary_id
      WHERE experiments.id = $1
    SQL

    if row.fetch("glossary_revision_id")
      assert_equal seed.fetch(:glossary_revision_id).to_s, row.fetch("glossary_revision_id")
      assert_equal row.fetch("project_owner_id"), row.fetch("glossary_owner_id")
    else
      assert_equal seed.fetch(:new_owner_id).to_s, row.fetch("project_owner_id")
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
