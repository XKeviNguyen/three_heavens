require "test_helper"
require_relative "../../../support/operations_test_helper"

class Operations::Backup::BundleCreatorTest < ActiveSupport::TestCase
  include OperationsTestHelper

  test "creates a restrictive complete versioned bundle without secrets or private names" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        FileUtils.mkdir_p(File.join(storage, "ab", "cd"))
        File.binwrite(File.join(storage, "ab", "cd", "opaque-key"), "exact private bytes")
        runner = FakeDumpRunner.new

        result = create_test_bundle(root: root, storage_root: storage, runner: runner)
        verified = Operations::Restore::BundleVerifier.call(result.path)
        manifest_text = result.path.join("manifest.json").read

        assert_equal FIXED_BACKUP_ID, result.backup_id
        assert result.path.join("COMPLETE").file?
        assert_equal 0o700, result.path.stat.mode & 0o777
        %w[manifest.json primary.dump storage.tar.gz COMPLETE].each do |filename|
          assert_equal 0o600, result.path.join(filename).stat.mode & 0o777
        end
        assert_equal 1, verified.manifest.dig("aggregates", "storage_file_count")
        assert_equal "custom", verified.manifest.dig("database", "dump_format")
        assert_not_includes manifest_text, "synthetic_password"
        assert_not_includes manifest_text, "private bytes"
        assert_not_includes manifest_text, "opaque-key"
        assert_equal [ "pg_dump", "--format=custom", "--no-owner", "--no-privileges" ], runner.calls.first[:arguments].first(4)
        assert_not runner.calls.first[:arguments].join(" ").include?("postgresql://")
        assert_equal "synthetic_database", runner.calls.first[:environment]["PGDATABASE"]
        assert_equal "synthetic_user", runner.calls.first[:environment]["PGUSER"]
        assert_equal "synthetic_password", runner.calls.first[:environment]["PGPASSWORD"]
      end
    end
  end

  test "command failure leaves no valid completed bundle" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        assert_raises(Operations::CommandRunner::CommandFailed) do
          create_test_bundle(root: root, storage_root: storage, runner: FakeDumpRunner.new(fail: true))
        end

        entries = Pathname.new(root).children
        assert_equal 1, entries.size
        assert entries.first.basename.to_s.start_with?(".partial-")
        assert_not entries.first.join("COMPLETE").exist?
        assert_raises(Operations::Restore::BundleVerifier::InvalidBundle) do
          Operations::Restore::BundleVerifier.call(entries.first)
        end
      end
    end
  end

  test "rejects unsafe destination and backup collisions" do
    Dir.mktmpdir("three-heavens-storage-") do |storage|
      assert_raises(Operations::PathSafety::UnsafePath) do
        create_test_bundle(root: "/", storage_root: storage)
      end
    end

    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        create_test_bundle(root: root, storage_root: storage)
        assert_raises(Operations::Backup::BundleCreator::BackupFailed) do
          create_test_bundle(root: root, storage_root: storage)
        end
      end
    end
  end

  test "rejects a destination beneath live storage before pg_dump or bundle creation" do
    Dir.mktmpdir("three-heavens-storage-") do |storage|
      runner = FakeDumpRunner.new

      assert_raises(Operations::PathSafety::UnsafePath) do
        create_test_bundle(root: File.join(storage, "backups", "nested"), storage_root: storage, runner: runner)
      end

      assert_empty runner.calls || []
      assert_not Pathname.new(storage).join("backups").exist?
    end
  end

  test "rejects a storage symlink instead of following it" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        File.symlink("/etc/passwd", File.join(storage, "unsafe-link"))

        assert_raises(Operations::Backup::StorageArchive::UnsafeStorage) do
          create_test_bundle(root: root, storage_root: storage)
        end
      end
    end
  end
end
