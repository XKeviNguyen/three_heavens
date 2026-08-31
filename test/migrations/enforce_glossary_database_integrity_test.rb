require "test_helper"
require Rails.root.join("db/migrate/20260901025500_enforce_glossary_database_integrity")

class EnforceGlossaryDatabaseIntegrityTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class LegacyDatabase < ActiveRecord::Base
    self.abstract_class = true
  end

  test "legacy integrity preflight accepts a valid existing revision" do
    with_legacy_schema do |connection|
      seed_legacy_records(connection)

      migrate_up(connection)

      assert connection.column_exists?(:glossary_revisions, :entry_set_sealed)
      assert connection.select_value("SELECT entry_set_sealed FROM glossary_revisions WHERE id = 1")
    end
  end

  test "legacy integrity preflight rejects a mismatched digest without repairing it" do
    with_legacy_schema do |connection|
      mismatched_digest = "0" * 64
      seed_legacy_records(connection, digest: mismatched_digest)

      error = assert_raises(ActiveRecord::StatementInvalid) { migrate_up(connection) }

      assert_includes error.message, "Existing glossary revisions must have 1-100 entries"
      assert_equal mismatched_digest, connection.select_value("SELECT configuration_digest FROM glossary_revisions WHERE id = 1")
      assert_not connection.column_exists?(:glossary_revisions, :entry_set_sealed)
    end
  end

  test "legacy integrity preflight rejects a cross-owner experiment link without repairing it" do
    with_legacy_schema do |connection|
      seed_legacy_records(connection, project_owner_id: 1, glossary_owner_id: 2)

      error = assert_raises(ActiveRecord::StatementInvalid) { migrate_up(connection) }

      assert_includes error.message, "Existing experiment glossary ownership integrity check failed"
      assert_equal 1, connection.select_value("SELECT glossary_revision_id FROM experiments WHERE id = 1")
      assert_equal [ 1, 2 ], connection.select_rows(<<~SQL).first
        SELECT projects.user_id, glossaries.user_id
        FROM projects CROSS JOIN glossaries
        WHERE projects.id = 1 AND glossaries.id = 1
      SQL
      assert_not connection.column_exists?(:glossary_revisions, :entry_set_sealed)
    end
  end

  test "database refuses to seal a callback-bypassing revision with no entries" do
    with_migrated_legacy_schema do |connection|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        insert_and_seal_revision(connection, revision_id: 2, entries: [])
      end

      assert_equal "23514", error.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      assert_nil connection.select_value("SELECT id FROM glossary_revisions WHERE id = 2")
    end
  end

  test "database refuses to seal a callback-bypassing revision above the entry limit" do
    with_migrated_legacy_schema do |connection|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        insert_and_seal_revision(
          connection,
          revision_id: 2,
          entries: raw_entries(GlossaryRevision::MAXIMUM_ENTRIES + 1)
        )
      end

      assert_equal "23514", error.cause.result.error_field(PG::Result::PG_DIAG_SQLSTATE)
      assert_nil connection.select_value("SELECT id FROM glossary_revisions WHERE id = 2")
    end
  end

  test "database seals callback-bypassing revisions at both valid entry bounds" do
    with_migrated_legacy_schema do |connection|
      [ 1, GlossaryRevision::MAXIMUM_ENTRIES ].each_with_index do |entry_count, index|
        revision_id = index + 2
        insert_and_seal_revision(connection, revision_id:, entries: raw_entries(entry_count))

        assert connection.select_value(<<~SQL)
          SELECT entry_set_sealed FROM glossary_revisions WHERE id = #{revision_id}
        SQL
        assert_equal entry_count, connection.select_value(<<~SQL)
          SELECT count(*) FROM glossary_entries WHERE glossary_revision_id = #{revision_id}
        SQL
        assert_equal raw_configuration_digest(raw_entries(entry_count)), connection.select_value(<<~SQL)
          SELECT configuration_digest FROM glossary_revisions WHERE id = #{revision_id}
        SQL
      end
    end
  end

  private

  def migrate_up(connection)
    migration = EnforceGlossaryDatabaseIntegrity.new
    migration.define_singleton_method(:connection) { connection }
    migration.suppress_messages do
      connection.transaction { migration.migrate(:up) }
    end
  end

  def with_migrated_legacy_schema
    with_legacy_schema do |connection|
      seed_legacy_records(connection)
      migrate_up(connection)
      yield connection
    end
  end

  def with_legacy_schema
    schema = "glossary_integrity_test_#{SecureRandom.hex(8)}"
    quoted_schema = ActiveRecord::Base.connection.quote_table_name(schema)
    ActiveRecord::Base.connection.execute("CREATE SCHEMA #{quoted_schema}")
    schema_created = true
    database = LegacyDatabase
    database.establish_connection(
      ActiveRecord::Base.connection_db_config.configuration_hash.merge(schema_search_path: "#{schema},public")
    )
    connection = database.connection
    connection.schema_search_path = "#{schema},public"
    create_legacy_tables(connection)
    yield connection
  ensure
    database&.connection_pool&.disconnect!
    ActiveRecord::Base.connection.execute("DROP SCHEMA #{quoted_schema} CASCADE") if schema_created
  end

  def create_legacy_tables(connection)
    connection.execute(<<~SQL)
      CREATE TABLE projects (id bigint PRIMARY KEY, user_id bigint NOT NULL);
      CREATE TABLE documents (id bigint PRIMARY KEY, project_id bigint NOT NULL);
      CREATE TABLE glossaries (id bigint PRIMARY KEY, user_id bigint NOT NULL);
      CREATE TABLE glossary_revisions (
        id bigint PRIMARY KEY,
        glossary_id bigint NOT NULL,
        source_language varchar NOT NULL,
        target_language varchar NOT NULL,
        configuration_digest varchar NOT NULL
      );
      CREATE TABLE glossary_entries (
        id bigint PRIMARY KEY,
        glossary_revision_id bigint NOT NULL,
        position integer NOT NULL,
        source_term varchar NOT NULL,
        preferred_target_term varchar NOT NULL,
        note varchar
      );
      CREATE TABLE experiments (
        id bigint PRIMARY KEY,
        document_id bigint NOT NULL,
        glossary_revision_id bigint
      );
    SQL
  end

  def seed_legacy_records(connection, project_owner_id: 1, glossary_owner_id: 1, digest: valid_digest)
    connection.execute(<<~SQL)
      INSERT INTO projects (id, user_id) VALUES (1, #{project_owner_id});
      INSERT INTO documents (id, project_id) VALUES (1, 1);
      INSERT INTO glossaries (id, user_id) VALUES (1, #{glossary_owner_id});
      INSERT INTO glossary_revisions (
        id, glossary_id, source_language, target_language, configuration_digest
      )
      VALUES (1, 1, 'Vietnamese', 'Japanese', #{connection.quote(digest)});
      INSERT INTO glossary_entries (
        id, glossary_revision_id, position, source_term, preferred_target_term, note
      ) VALUES (1, 1, 1, 'Sabbath', '安息日', NULL);
      INSERT INTO experiments (id, document_id, glossary_revision_id) VALUES (1, 1, 1);
    SQL
  end

  def valid_digest
    raw_configuration_digest([ {
      position: 1,
      source_term: "Sabbath",
      preferred_target_term: "安息日",
      note: nil
    } ])
  end

  def insert_and_seal_revision(connection, revision_id:, entries:)
    connection.transaction do
      connection.execute("INSERT INTO glossaries (id, user_id) VALUES (#{revision_id}, 1)")
      connection.execute(<<~SQL)
        INSERT INTO glossary_revisions (
          id, glossary_id, source_language, target_language, configuration_digest, entry_set_sealed
        ) VALUES (
          #{revision_id}, #{revision_id}, 'Vietnamese', 'Japanese',
          #{connection.quote(raw_configuration_digest(entries))}, FALSE
        )
      SQL
      entries.each_with_index do |entry, index|
        connection.execute(<<~SQL)
          INSERT INTO glossary_entries (
            id, glossary_revision_id, position, source_term, preferred_target_term, note
          ) VALUES (
            #{revision_id * 1_000 + index}, #{revision_id}, #{entry.fetch(:position)},
            #{connection.quote(entry.fetch(:source_term))},
            #{connection.quote(entry.fetch(:preferred_target_term))},
            #{connection.quote(entry.fetch(:note))}
          )
        SQL
      end
      connection.execute("SET CONSTRAINTS seal_glossary_revision_entry_set_trigger IMMEDIATE")
    end
  end

  def raw_entries(count)
    count.times.map do |index|
      {
        position: index + 1,
        source_term: "Source term #{index + 1}",
        preferred_target_term: "Target term #{index + 1}",
        note: index.even? ? "Note #{index + 1}" : nil
      }
    end
  end

  def raw_configuration_digest(entries)
    Digest::SHA256.hexdigest(
      JSON.generate(
        "source_language" => "Vietnamese",
        "target_language" => "Japanese",
        "entries" => entries.map(&:stringify_keys)
      )
    )
  end
end
