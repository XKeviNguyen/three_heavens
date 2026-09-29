require "test_helper"
require Rails.root.join("db/migrate/20260929120000_make_configuration_digests_restore_safe")

class Operations::Restore::LegacyDigestFunctionsTest < ActiveSupport::TestCase
  SIGNATURES = Operations::Restore::LegacyDigestFunctions::DEFINITIONS.keys

  test "replaces only legacy bodies with exactly the definitions the corrective migration installs" do
    corrected = function_sources
    assert corrected.values.none? { |source| source.include?("encode(digest(") }

    connection.transaction(requires_new: true) do
      migration = MakeConfigurationDigestsRestoreSafe.new
      migration.define_singleton_method(:connection) { ActiveRecord::Base.connection }
      migration.suppress_messages { migration.migrate(:down) }
      assert function_sources.values.all? { |source| source.include?("encode(digest(") }

      assert_equal 3, Operations::Restore::LegacyDigestFunctions.upgrade!(connection.raw_connection)
      assert_equal corrected, function_sources
      assert_equal 0, Operations::Restore::LegacyDigestFunctions.upgrade!(connection.raw_connection)
      raise ActiveRecord::Rollback
    end
  end

  test "leaves a non-legacy definition untouched" do
    connection.transaction(requires_new: true) do
      connection.execute(<<~SQL)
        CREATE OR REPLACE FUNCTION public.methodology_revision_configuration_digest(
          source_language text, target_language text, guidance text
        ) RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$ SELECT 'later-release definition'::text $$;
      SQL

      assert_equal 0, Operations::Restore::LegacyDigestFunctions.upgrade!(connection.raw_connection)
      assert_includes function_sources.fetch(SIGNATURES.first), "later-release definition"
      raise ActiveRecord::Rollback
    end
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  # Uncached: the upgrade writes through the raw connection, bypassing Active
  # Record's query cache invalidation.
  def function_sources
    connection.uncached do
      SIGNATURES.index_with do |signature|
        connection.select_value("SELECT prosrc FROM pg_proc WHERE oid = #{connection.quote(signature)}::regprocedure")
      end
    end
  end
end
