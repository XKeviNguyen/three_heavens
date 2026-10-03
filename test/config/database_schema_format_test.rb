require "test_helper"

class DatabaseSchemaFormatTest < ActiveSupport::TestCase
  test "uses SQL only for primary databases" do
    configurations = ActiveRecord::Base.configurations

    assert_equal :sql, configurations.configs_for(env_name: "development", name: "primary").schema_format
    assert_equal :sql, configurations.configs_for(env_name: "test", name: "primary").schema_format
    assert_equal :sql, configurations.configs_for(env_name: "production", name: "primary").schema_format
    %w[cache queue cable].each do |name|
      assert_equal :ruby, configurations.configs_for(env_name: "production", name: name).schema_format
    end
  end

  # The test database is loaded from db/structure.sql. When PostgreSQL deparses
  # every loaded constraint and index exactly as the file spells it, dumping
  # the schema again reproduces the file, so a migration's dump shows only
  # its own change instead of rewording unrelated constraints.
  test "structure.sql spells constraints and indexes as PostgreSQL deparses them" do
    structure = Rails.root.join("db/structure.sql").read
    connection = ActiveRecord::Base.connection

    constraints = indexes = nil
    # pg_dump deparses with an empty search_path, qualifying every name.
    connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL search_path TO ''")
      constraints = connection.select_rows(<<~SQL)
        SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
        WHERE contype = 'c' AND connamespace = 'public'::regnamespace
      SQL
      indexes = connection.select_values(<<~SQL)
        SELECT pg_get_indexdef(indexrelid) FROM pg_index
        JOIN pg_class ON pg_class.oid = pg_index.indrelid
        WHERE pg_class.relnamespace = 'public'::regnamespace AND NOT pg_index.indisprimary
          AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conindid = pg_index.indexrelid)
      SQL
      raise ActiveRecord::Rollback
    end

    assert_operator constraints.size, :>, 100
    constraints.each do |name, definition|
      assert_includes structure, "CONSTRAINT #{name} #{definition}"
    end
    indexes.each { |definition| assert_includes structure, "#{definition};" }
  end
end
