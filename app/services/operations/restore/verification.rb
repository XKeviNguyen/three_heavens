module Operations
  module Restore
    class Verification
      class RestoreFailed < StandardError; end

      Result = Data.define(:bundle, :storage_result, :integrity)

      def self.call(bundle_path:, database_url:, storage_path:, **options)
        new(
          bundle_path: bundle_path,
          database_url: database_url,
          storage_path: storage_path,
          **options
        ).call
      end

      def initialize(bundle_path:, database_url:, storage_path:,
                     command_runner: Operations::CommandRunner.new,
                     bundle_verifier: BundleVerifier,
                     database_target_factory: ->(**arguments) { DatabaseTarget.new(**arguments) },
                     integrity_auditor: IntegrityAudit,
                     live_database_url: ENV["DATABASE_URL"], clock: -> { Time.current })
        @bundle_path = bundle_path
        @database_url = database_url.to_s
        @storage_path = storage_path
        @command_runner = command_runner
        @bundle_verifier = bundle_verifier
        @database_target_factory = database_target_factory
        @integrity_auditor = integrity_auditor
        @live_database_url = live_database_url
        @clock = clock
      end

      def call
        started_at = clock.call
        Operations::EventLogger.emit("restore_verification_started", outcome: "started")
        bundle = bundle_verifier.call(bundle_path)
        verify_dump_catalog!(bundle)
        validated_storage = StorageExtractor.validate(
          archive_path: bundle.path.join(Operations::Backup::Manifest::STORAGE_FILENAME)
        )
        validate_storage_aggregates!(bundle, validated_storage)
        database_target_factory.call(
          target_url: database_url,
          live_url: live_database_url
        ).validate!
        validate_storage_target_before_database_restore!
        restore_database!(bundle)
        storage_result = StorageExtractor.call(
          archive_path: bundle.path.join(Operations::Backup::Manifest::STORAGE_FILENAME),
          destination: storage_path
        )
        validate_storage_aggregates!(bundle, storage_result)
        integrity = integrity_auditor.call(
          database_url: database_url,
          storage_path: storage_path,
          expected_schema_version: bundle.manifest.dig("database", "schema_version")
        )
        raise RestoreFailed, "restore integrity audit found critical problems" unless integrity.successful?

        Operations::EventLogger.emit(
          "restore_verification_completed",
          outcome: "success",
          duration_ms: elapsed_ms(started_at),
          count: integrity.blob_count
        )
        Result.new(bundle: bundle, storage_result: storage_result, integrity: integrity)
      rescue StandardError => error
        Operations::EventLogger.emit(
          "restore_verification_failed",
          severity: :error,
          outcome: safe_failure_code(error)
        )
        raise
      end

      private

      attr_reader :bundle_path, :bundle_verifier, :clock, :command_runner,
                  :database_target_factory, :database_url, :integrity_auditor,
                  :live_database_url, :storage_path

      def verify_dump_catalog!(bundle)
        command_runner.call(
          environment: {},
          arguments: [
            "pg_restore", "--list",
            bundle.path.join(Operations::Backup::Manifest::DATABASE_FILENAME).to_s
          ]
        )
      end

      def validate_storage_target_before_database_restore!
        path = Pathname.new(storage_path.to_s)
        raise RestoreFailed, "RESTORE_STORAGE_PATH is required" if storage_path.to_s.strip.empty?
        raise RestoreFailed, "restore storage path must be absolute" unless path.absolute?
        raise RestoreFailed, "restore storage path must be empty" if path.exist? && (!path.directory? || path.children.any?)
      end

      def restore_database!(bundle)
        command_runner.call(
          environment: { "PGDATABASE" => database_url },
          arguments: [
            "pg_restore", "--exit-on-error", "--no-owner", "--no-privileges",
            "--dbname=",
            bundle.path.join(Operations::Backup::Manifest::DATABASE_FILENAME).to_s
          ]
        )
      end

      def validate_storage_aggregates!(bundle, storage_result)
        aggregates = bundle.manifest.fetch("aggregates")
        unless storage_result.file_count == aggregates.fetch("storage_file_count") &&
            storage_result.total_bytes == aggregates.fetch("storage_total_bytes")
          raise RestoreFailed, "storage archive aggregates do not match the manifest"
        end
      end

      def elapsed_ms(started_at)
        [ ((clock.call - started_at) * 1000).round, 0 ].max
      end

      def safe_failure_code(error)
        case error
        when BundleVerifier::InvalidBundle then "invalid_bundle"
        when DatabaseTarget::UnsafeDatabase then "unsafe_database"
        when StorageExtractor::UnsafeArchive then "unsafe_archive"
        when IntegrityAudit::AuditFailed then "integrity_audit_failed"
        when Operations::CommandRunner::CommandFailed then "command_failed"
        else "restore_failed"
        end
      end
    end
  end
end
