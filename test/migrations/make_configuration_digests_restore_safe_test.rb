require "test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/translation_reference_test_helper"
require Rails.root.join("db/migrate/20260929120000_make_configuration_digests_restore_safe")

# pg_restore loads every table with `search_path = ''` and evaluates each
# table's inline CHECK constraints during COPY, before any trigger exists. A
# temporary copy of a table with its CHECK constraints reproduces that state.
class MakeConfigurationDigestsRestoreSafeTest < ActiveSupport::TestCase
  include MethodologyProfileTestHelper
  include TranslationReferenceTestHelper

  CHECKED_TABLES = %w[methodology_profile_revisions translation_reference_revisions].freeze

  setup do
    create_methodology_profile(guidance: "Giữ nguyên sắc thái thần học. 🙏🏽")
    create_translation_reference(source_text: "Nguồn \\ thứ nhất.", approved_translation: "承認された翻訳。")
    @glossary = Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        name: "Restore glossary", description: "", source_language: "Vietnamese", target_language: "Japanese",
        entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "" } ]
      }
    )
  end

  test "digest-checked rows reload under the empty search_path pg_restore uses" do
    counts = CHECKED_TABLES.index_with { |table| connection.select_value("SELECT count(*) FROM public.#{table}") }
    assert counts.values.all?(&:positive?)

    with_restore_conditions do
      CHECKED_TABLES.each do |table|
        connection.execute("INSERT INTO pg_temp.restored_#{table} SELECT * FROM public.#{table}")
        assert_equal counts.fetch(table), connection.select_value("SELECT count(*) FROM pg_temp.restored_#{table}")
      end
      revision = @glossary.current_revision
      assert_equal revision.configuration_digest,
                   connection.select_value("SELECT public.glossary_revision_configuration_digest(#{revision.id})")
    end
  end

  test "the pre-correction function bodies fail under the same restore conditions" do
    with_restore_conditions do
      connection.execute("SET LOCAL search_path TO DEFAULT")
      run_migration(:down)
      connection.execute("SET LOCAL search_path TO ''")

      error = assert_raises(ActiveRecord::StatementInvalid) do
        connection.execute("INSERT INTO pg_temp.restored_methodology_profile_revisions SELECT * FROM public.methodology_profile_revisions")
      end
      assert_match(/function digest\(text, unknown\) does not exist/, error.message)
    end

    assert_equal 0, connection.select_value(<<~SQL)
      SELECT count(*) FROM pg_proc JOIN pg_namespace ON pg_namespace.oid = pg_proc.pronamespace
      WHERE pg_namespace.nspname = 'public' AND pg_proc.prosrc LIKE '%digest(%''sha256''%'
    SQL
  end

  test "up refuses to replace the functions when a stored digest would stop matching" do
    revision = MethodologyProfileRevision.last
    connection.transaction(requires_new: true) do
      connection.execute("ALTER TABLE public.methodology_profile_revisions DISABLE TRIGGER USER")
      connection.execute("ALTER TABLE public.methodology_profile_revisions DROP CONSTRAINT methodology_profile_revisions_payload_digest_check")
      connection.execute("UPDATE public.methodology_profile_revisions SET configuration_digest = repeat('0', 64) WHERE id = #{revision.id}")

      error = assert_raises(ActiveRecord::MigrationError) { run_migration(:up) }
      assert_includes error.message, "1 stored configuration digests would no longer match"
      raise ActiveRecord::Rollback
    end
    assert_equal revision.configuration_digest, revision.reload.configuration_digest
  end

  private

  def connection
    ActiveRecord::Base.connection
  end

  def run_migration(direction)
    migration = MakeConfigurationDigestsRestoreSafe.new
    migration.define_singleton_method(:connection) { ActiveRecord::Base.connection }
    migration.suppress_messages { migration.migrate(direction) }
  end

  def with_restore_conditions
    search_path = connection.select_value("SHOW search_path")
    connection.transaction(requires_new: true) do
      CHECKED_TABLES.each do |table|
        connection.execute("CREATE TEMP TABLE restored_#{table} (LIKE public.#{table} INCLUDING CONSTRAINTS)")
      end
      connection.execute("SET LOCAL search_path TO ''")
      yield
      raise ActiveRecord::Rollback
    end
    assert_equal search_path, connection.select_value("SHOW search_path")
  end
end
