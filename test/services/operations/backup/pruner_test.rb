require "test_helper"
require_relative "../../../support/operations_test_helper"

class Operations::Backup::PrunerTest < ActiveSupport::TestCase
  include OperationsTestHelper

  test "dry run and execution affect only valid completed bundles selected by bounded policy" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        old = create_test_bundle(
          root: root,
          storage_root: storage,
          backup_id: "20260801T010203Z-111111111111111111111111",
          at: Time.utc(2026, 8, 1)
        ).path
        recent = create_test_bundle(
          root: root,
          storage_root: storage,
          backup_id: "20260829T010203Z-222222222222222222222222",
          at: Time.utc(2026, 8, 29)
        ).path
        unrelated = Pathname.new(root).join("unrelated-private-directory")
        unrelated.mkdir
        unrelated.join("keep-me").write("safe")
        symlink = Pathname.new(root).join("20260701T010203Z-333333333333333333333333")
        File.symlink(unrelated, symlink)

        dry_run = Operations::Backup::Pruner.call(
          root: root,
          dry_run: true,
          keep_last: 1,
          older_than_days: 15,
          clock: -> { Time.utc(2026, 8, 30) }
        )
        assert_equal 2, dry_run.recognized_count
        assert_equal 1, dry_run.selected_count
        assert old.exist?

        executed = Operations::Backup::Pruner.call(
          root: root,
          dry_run: false,
          keep_last: 1,
          older_than_days: 15,
          clock: -> { Time.utc(2026, 8, 30) }
        )
        assert_equal 1, executed.deleted_count
        assert_not old.exist?
        assert recent.exist?
        assert unrelated.join("keep-me").exist?
        assert symlink.symlink?
      end
    end
  end

  test "rejects dangerous roots and invalid bounds" do
    assert_raises(Operations::Backup::Pruner::InvalidPolicy) do
      Operations::Backup::Pruner.call(root: "/", dry_run: true, keep_last: 1)
    end
    assert_raises(Operations::Backup::Pruner::InvalidPolicy) do
      Operations::Backup::Pruner.call(root: "/tmp", dry_run: true, keep_last: -1)
    end
    assert_raises(Operations::Backup::Pruner::InvalidPolicy) do
      Operations::Backup::Pruner.call(root: "/tmp", dry_run: true)
    end
  end
end
