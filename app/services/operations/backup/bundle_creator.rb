require "fileutils"
require "securerandom"

module Operations
  module Backup
    class BundleCreator
      class BackupFailed < StandardError; end

      Result = Data.define(:backup_id, :path)

      def self.call(destination_root:, database_url: ENV["DATABASE_URL"], storage_root: nil, **options)
        new(
          destination_root: destination_root,
          database_url: database_url,
          storage_root: storage_root,
          **options
        ).call
      end

      def initialize(destination_root:, database_url:, storage_root: nil,
                     command_runner: Operations::CommandRunner.new,
                     clock: -> { Time.current }, id_generator: nil,
                     release_sha: ENV["KAMAL_VERSION"] || ENV["RELEASE_SHA"],
                     schema_version: -> { ActiveRecord::Base.connection_pool.migration_context.current_version })
        @destination_root_value = destination_root
        @database_url = database_url.to_s
        @storage_root_value = storage_root || configured_storage_root
        @command_runner = command_runner
        @clock = clock
        @id_generator = id_generator || -> { "#{clock.call.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(12)}" }
        @release_sha = release_sha
        @schema_version = schema_version
      end

      def call
        validate_configuration!
        destination_root = Operations::PathSafety.prepare_root!(
          destination_root_value,
          create: true,
          forbidden: [ Rails.root, storage_root_value ]
        )
        storage_root = Operations::PathSafety.prepare_root!(storage_root_value)
        backup_id = id_generator.call.to_s
        validate_backup_id!(backup_id)
        partial_path = Operations::PathSafety.child!(destination_root, ".partial-#{backup_id}")
        final_path = Operations::PathSafety.child!(destination_root, backup_id)
        reject_collision!(partial_path, final_path)

        started_at = clock.call
        Operations::EventLogger.emit("backup_started", outcome: "started")
        FileUtils.mkdir(partial_path, mode: 0o700)
        database_path = partial_path.join(Manifest::DATABASE_FILENAME)
        storage_path = partial_path.join(Manifest::STORAGE_FILENAME)
        dump_primary!(database_path)
        storage_result = StorageArchive.create(source: storage_root, destination: storage_path)
        manifest = Manifest.build(
          backup_id: backup_id,
          created_at: started_at,
          release_sha: release_sha,
          schema_version: schema_version.call,
          database_path: database_path,
          storage_path: storage_path,
          storage_result: storage_result
        )
        write_manifest!(partial_path, manifest)
        write_completion_marker!(partial_path)
        fsync_directory(partial_path)
        File.rename(partial_path, final_path)
        fsync_directory(destination_root)
        Operations::EventLogger.emit(
          "backup_completed",
          outcome: "success",
          duration_ms: elapsed_ms(started_at),
          count: storage_result.file_count
        )
        Result.new(backup_id: backup_id, path: final_path)
      rescue StandardError => error
        remove_completion_marker(partial_path) if defined?(partial_path) && partial_path
        Operations::EventLogger.emit("backup_failed", severity: :error, outcome: safe_failure_code(error))
        raise
      end

      private

      attr_reader :clock, :command_runner, :database_url, :destination_root_value,
                  :id_generator, :release_sha, :schema_version, :storage_root_value

      def validate_configuration!
        raise BackupFailed, "DATABASE_URL is required" if database_url.empty?
        raise BackupFailed, "storage root is required" if storage_root_value.to_s.empty?
      end

      def configured_storage_root
        service = ActiveStorage::Blob.service
        return service.root if service.respond_to?(:root)

        raise BackupFailed, "the configured Active Storage service is not a local disk service"
      end

      def validate_backup_id!(backup_id)
        return if backup_id.match?(/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{24}\z/)

        raise BackupFailed, "backup ID generator returned an unsafe value"
      end

      def reject_collision!(partial_path, final_path)
        raise BackupFailed, "backup ID collision" if partial_path.exist? || partial_path.symlink? || final_path.exist? || final_path.symlink?
      end

      def dump_primary!(path)
        command_runner.call(
          environment: PostgresConnectionEnvironment.from_url(database_url),
          arguments: [
            "pg_dump", "--format=custom", "--no-owner", "--no-privileges",
            "--file", path.to_s
          ]
        )
        raise BackupFailed, "pg_dump did not create an artifact" unless path.file? && path.size.positive?

        File.chmod(0o600, path)
        File.open(path, "rb") { |file| file.fsync }
      end

      def write_manifest!(bundle_path, manifest)
        path = bundle_path.join(Manifest::MANIFEST_FILENAME)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write(JSON.generate(manifest))
          file.write("\n")
          file.flush
          file.fsync
        end
      end

      def write_completion_marker!(bundle_path)
        manifest_path = bundle_path.join(Manifest::MANIFEST_FILENAME)
        marker_path = bundle_path.join(Manifest::COMPLETION_FILENAME)
        File.open(marker_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{Manifest.sha256(manifest_path)}\n")
          file.flush
          file.fsync
        end
      end

      def remove_completion_marker(partial_path)
        marker = partial_path.join(Manifest::COMPLETION_FILENAME)
        FileUtils.rm_f(marker) if marker.file? && !marker.symlink?
      end

      def fsync_directory(path)
        File.open(path, "r") { |directory| directory.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP
        nil
      end

      def elapsed_ms(started_at)
        [ ((clock.call - started_at) * 1000).round, 0 ].max
      end

      def safe_failure_code(error)
        case error
        when Operations::CommandRunner::CommandFailed then "command_failed"
        when Operations::PathSafety::UnsafePath then "unsafe_path"
        when StorageArchive::UnsafeStorage then "unsafe_storage"
        else "backup_failed"
        end
      end
    end
  end
end
