require "test_helper"
require "rubygems/package"
require "zlib"
require_relative "../../../support/operations_test_helper"

class Operations::Restore::VerificationTest < ActiveSupport::TestCase
  include OperationsTestHelper

  SuccessfulIntegrity = Data.define(:blob_count, :critical_count) do
    def successful?
      true
    end
  end

  test "verifies artifacts before isolated database restore and storage extraction" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        FileUtils.mkdir_p(File.join(storage, "ab", "cd"))
        File.binwrite(File.join(storage, "ab", "cd", "opaque-key"), "bytes")
        bundle = create_test_bundle(root: root, storage_root: storage).path
        restore_storage = File.join(root, "isolated-restore")
        calls = []
        runner = lambda do |environment:, arguments:|
          calls << { environment: environment, arguments: arguments }
          true
        end
        target = Object.new
        target.define_singleton_method(:validate!) { calls << :database_validated; true }
        integrity = Object.new
        integrity.define_singleton_method(:call) do |**arguments|
          calls << [ :integrity, arguments.except(:database_url) ]
          SuccessfulIntegrity.new(blob_count: 1, critical_count: 0)
        end

        result = Operations::Restore::Verification.call(
          bundle_path: bundle,
          database_url: "postgresql://restore_user:restore_password@localhost/isolated_restore",
          storage_path: restore_storage,
          command_runner: runner,
          database_target_factory: ->(**) { target },
          integrity_auditor: integrity,
          live_database_url: "postgresql://live_user:live_password@localhost/live"
        )

        assert_equal 1, result.storage_result.file_count
        assert_equal "bytes", File.binread(File.join(restore_storage, "ab", "cd", "opaque-key"))
        command_calls = calls.grep(Hash)
        assert_equal "--list", command_calls.first[:arguments][1]
        assert_equal "pg_restore", command_calls.second[:arguments].first
        command_calls.each do |call|
          assert_not call[:arguments].join(" ").include?("restore_password")
          assert_not call[:arguments].join(" ").include?("postgresql://")
        end
        assert command_calls.second[:environment].key?("PGDATABASE")
      end
    end
  end

  test "tampered bundle fails before database target or restore command" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        bundle = create_test_bundle(root: root, storage_root: storage).path
        File.open(bundle.join("primary.dump"), "ab") { |file| file.write("tamper") }
        called = []

        assert_raises(Operations::Restore::BundleVerifier::InvalidBundle) do
          Operations::Restore::Verification.call(
            bundle_path: bundle,
            database_url: "postgresql://restore/isolated",
            storage_path: File.join(root, "restore"),
            command_runner: ->(**) { called << :command },
            database_target_factory: ->(**) { called << :database },
            integrity_auditor: ->(**) { called << :integrity },
            live_database_url: "postgresql://live/current"
          )
        end
        assert_empty called
      end
    end
  end

  test "malicious storage archive fails before database target or restore command" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        bundle = create_test_bundle(root: root, storage_root: storage).path
        archive = bundle.join("storage.tar.gz")
        File.open(archive, "wb") do |file|
          Zlib::GzipWriter.wrap(file) do |gzip|
            Gem::Package::TarWriter.new(gzip) do |tar|
              tar.add_file_simple("../escape", 0o600, 1) { |entry| entry.write("x") }
            end
          end
        end
        rewrite_manifest(bundle) do |manifest|
          metadata = manifest.fetch("artifacts").fetch("storage.tar.gz")
          metadata["bytes"] = archive.size
          metadata["sha256"] = Operations::Backup::Manifest.sha256(archive)
          manifest.fetch("aggregates")["storage_file_count"] = 1
          manifest.fetch("aggregates")["storage_total_bytes"] = 1
        end
        called = []

        assert_raises(Operations::Restore::StorageExtractor::UnsafeArchive) do
          Operations::Restore::Verification.call(
            bundle_path: bundle,
            database_url: "postgresql://restore/isolated",
            storage_path: File.join(root, "restore"),
            command_runner: lambda do |environment:, arguments:|
              called << :restore unless arguments.include?("--list")
              true
            end,
            database_target_factory: ->(**) { called << :database },
            live_database_url: "postgresql://live/current"
          )
        end
        assert_empty called
        assert_not File.exist?(File.join(root, "escape"))
      end
    end
  end

  test "refuses absent or non-empty storage target before database restore" do
    Dir.mktmpdir("three-heavens-backups-") do |root|
      Dir.mktmpdir("three-heavens-storage-") do |storage|
        bundle = create_test_bundle(root: root, storage_root: storage).path
        nonempty = File.join(root, "restore")
        FileUtils.mkdir_p(nonempty)
        File.write(File.join(nonempty, "existing"), "preserve")
        restore_calls = 0
        runner = lambda do |environment:, arguments:|
          restore_calls += 1 unless arguments.include?("--list")
          true
        end
        target = Object.new
        target.define_singleton_method(:validate!) { true }

        assert_raises(Operations::Restore::Verification::RestoreFailed) do
          Operations::Restore::Verification.call(
            bundle_path: bundle,
            database_url: "postgresql://restore/isolated",
            storage_path: nonempty,
            command_runner: runner,
            database_target_factory: ->(**) { target },
            live_database_url: "postgresql://live/current"
          )
        end
        assert_equal 0, restore_calls
        assert_equal "preserve", File.read(File.join(nonempty, "existing"))
      end
    end
  end
end
