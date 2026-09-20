require "digest"
require "stringio"
require "tmpdir"

module Operations
  module Restore
    class LocalDrill
      class UnsafeDrill < StandardError; end

      Result = Data.define(:blob_count, :attachment_count, :document_count, :critical_count, :warning_count)

      DATABASE_PREFIX = "three_heavens_restore_drill_"
      CONFIRMATION_NAME = "ALLOW_DISPOSABLE_RESTORE_DRILL"
      PRODUCTION_MARKER_NAMES = %w[
        DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL
        KAMAL_VERSION KAMAL_CONTAINER_NAME
      ].freeze

      def self.call(environment: ENV)
        new(environment: environment).call
      end

      def initialize(environment:)
        @environment = environment
        @database_names = []
      end

      def call
        validate_intent!
        original_configuration = ActiveRecord::Base.connection_db_config.configuration_hash
        original_storage_service = ActiveStorage::Blob.service
        original_storage_services = ActiveStorage::Blob.services
        admin = PG.connect(pg_options(original_configuration, database: "postgres"))

        Dir.mktmpdir("three-heavens-restore-drill-") do |temporary_root|
          source_database = create_database!(admin, "source")
          target_database = create_database!(admin, "target")
          source_storage = File.join(temporary_root, "source-storage")
          restore_storage = File.join(temporary_root, "restore-storage")
          backup_root = File.join(temporary_root, "backups")
          FileUtils.mkdir_p(source_storage, mode: 0o700)
          configure_source!(original_configuration, source_database, source_storage)
          blob_key, expected_bytes = create_representative_data!
          source_connection = connection_string(original_configuration, source_database)
          target_connection = connection_string(original_configuration, target_database)
          bundle = Operations::Backup::BundleCreator.call(
            destination_root: backup_root,
            database_url: source_connection,
            storage_root: source_storage
          )
          verification = Verification.call(
            bundle_path: bundle.path,
            database_url: target_connection,
            storage_path: restore_storage,
            live_database_url: connection_string(original_configuration, original_configuration.fetch(:database))
          )
          verify_representative_data!(
            target_connection: target_connection,
            restore_storage: restore_storage,
            blob_key: blob_key,
            expected_bytes: expected_bytes
          )
          integrity = verification.integrity
          Result.new(
            blob_count: integrity.blob_count,
            attachment_count: integrity.attachment_count,
            document_count: integrity.document_source_attachment_count,
            critical_count: integrity.critical_count,
            warning_count: integrity.warning_count
          )
        end
      ensure
        ActiveStorage::Blob.service = original_storage_service if defined?(original_storage_service) && original_storage_service
        ActiveStorage::Blob.services = original_storage_services if defined?(original_storage_services) && original_storage_services
        restore_application_connection(original_configuration) if defined?(original_configuration) && original_configuration
        drop_databases!(admin) if defined?(admin) && admin
        admin&.close
      end

      private

      attr_reader :database_names, :environment

      def validate_intent!
        raise UnsafeDrill, "local restore drill is forbidden in production" if Rails.env.production?
        if PRODUCTION_MARKER_NAMES.any? { |name| environment[name].present? }
          raise UnsafeDrill, "local restore drill refuses production-marked environments"
        end
        unless environment[CONFIRMATION_NAME] == "1"
          raise UnsafeDrill, "set #{CONFIRMATION_NAME}=1 to create and remove disposable drill resources"
        end
      end

      def create_database!(admin, role)
        name = "#{DATABASE_PREFIX}#{role}_#{SecureRandom.hex(8)}"
        raise UnsafeDrill, "unsafe disposable database name" unless name.match?(/\A#{DATABASE_PREFIX}[a-z]+_[0-9a-f]{16}\z/)

        admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(name)}")
        database_names << name
        name
      end

      def configure_source!(configuration, database, storage_root)
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
        ActiveRecord::Base.establish_connection(configuration.merge(database: database))
        ActiveRecord::Schema.verbose = false
        ActiveRecord::Tasks::DatabaseTasks.load_schema(
          ActiveRecord::Base.connection_db_config,
          ActiveRecord::Base.connection_db_config.schema_format
        )
        services = ActiveStorage::Service::Registry.new(
          restore_drill: { service: "Disk", root: storage_root }
        )
        ActiveStorage::Blob.services = services
        ActiveStorage::Blob.service = services.fetch(:restore_drill)
      end

      def create_representative_data!
        bytes = "synthetic restore drill source bytes\n".b
        user = User.create!(
          email: "restore-drill-#{SecureRandom.hex(6)}@example.test",
          password: "synthetic restore drill password",
          role: :user,
          status: :active
        )
        project = user.projects.create!(
          name: "Synthetic restore drill",
          source_language: "Vietnamese",
          target_language: "Japanese"
        )
        document = project.documents.create!(
          title: "Synthetic restore source",
          source_text: "Synthetic source text"
        )
        document.source_file.attach(
          io: StringIO.new(bytes),
          filename: "synthetic-restore-source.txt",
          content_type: "text/plain"
        )
        document.update!(
          source_kind: :uploaded_file,
          source_format: "txt",
          original_filename: "synthetic-restore-source.txt",
          detected_content_type: "text/plain",
          original_byte_size: bytes.bytesize,
          source_sha256: Digest::SHA256.hexdigest(bytes),
          extraction_version: "restore-drill-v1"
        )
        [ document.source_file.blob.key, bytes ]
      end

      def verify_representative_data!(target_connection:, restore_storage:, blob_key:, expected_bytes:)
        connection = PG.connect(target_connection)
        document_count = Integer(connection.exec("SELECT COUNT(*) FROM documents").getvalue(0, 0))
        raise UnsafeDrill, "representative database record did not survive" unless document_count == 1

        object_path = Pathname.new(restore_storage).join(blob_key[0..1], blob_key[2..3], blob_key)
        unless object_path.file? && ActiveSupport::SecurityUtils.secure_compare(object_path.binread, expected_bytes)
          raise UnsafeDrill, "representative storage bytes did not survive"
        end
      ensure
        connection&.close
      end

      def restore_application_connection(configuration)
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
        ActiveRecord::Base.establish_connection(configuration)
      end

      def drop_databases!(admin)
        ActiveRecord::Base.connection_handler.clear_all_connections!(:all)
        database_names.reverse_each do |name|
          next unless name.match?(/\A#{DATABASE_PREFIX}[a-z]+_[0-9a-f]{16}\z/)

          admin.exec("DROP DATABASE IF EXISTS #{PG::Connection.quote_ident(name)} WITH (FORCE)")
        end
      end

      def connection_string(configuration, database)
        PG::Connection.connect_hash_to_string(pg_options(configuration, database: database))
      end

      def pg_options(configuration, database:)
        {
          host: configuration[:host],
          port: configuration[:port],
          user: configuration[:username],
          password: configuration[:password],
          dbname: database
        }.compact
      end
    end
  end
end
