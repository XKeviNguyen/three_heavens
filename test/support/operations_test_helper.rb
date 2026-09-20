require "tmpdir"

module OperationsTestHelper
  FIXED_BACKUP_ID = "20260830T010203Z-0123456789abcdef01234567"
  FIXED_TIME = Time.utc(2026, 8, 30, 1, 2, 3)

  FakeDumpRunner = Struct.new(:fail, :calls, keyword_init: true) do
    def call(environment:, arguments:)
      self.calls ||= []
      calls << { environment: environment, arguments: arguments }
      raise Operations::CommandRunner::CommandFailed.new(program: arguments.first, exit_status: 2) if fail

      destination = arguments.fetch(arguments.index("--file") + 1)
      File.binwrite(destination, "PGDMP\x01synthetic-test-dump")
      true
    end
  end

  def create_test_bundle(root:, storage_root:, backup_id: FIXED_BACKUP_ID, at: FIXED_TIME, runner: FakeDumpRunner.new)
    Operations::Backup::BundleCreator.call(
      destination_root: root,
      database_url: "postgresql://synthetic_user:synthetic_password@localhost/synthetic_database",
      storage_root: storage_root,
      command_runner: runner,
      clock: -> { at },
      id_generator: -> { backup_id },
      release_sha: "a" * 40,
      schema_version: -> { 20_260_830_010_203 }
    )
  end

  def rewrite_manifest(bundle_path)
    manifest_path = Pathname.new(bundle_path).join(Operations::Backup::Manifest::MANIFEST_FILENAME)
    manifest = JSON.parse(manifest_path.read)
    yield manifest
    manifest_path.write("#{JSON.generate(manifest)}\n")
    marker = Pathname.new(bundle_path).join(Operations::Backup::Manifest::COMPLETION_FILENAME)
    marker.write("#{Operations::Backup::Manifest.sha256(manifest_path)}\n")
  end
end
