require "digest"
require "json"

module Operations
  module Backup
    class Manifest
      FORMAT = "three-heavens-backup"
      VERSION = 1
      MANIFEST_FILENAME = "manifest.json"
      DATABASE_FILENAME = "primary.dump"
      STORAGE_FILENAME = "storage.tar.gz"
      COMPLETION_FILENAME = "COMPLETE"
      ARTIFACT_FILENAMES = [ DATABASE_FILENAME, STORAGE_FILENAME ].freeze

      def self.build(backup_id:, created_at:, release_sha:, schema_version:, database_path:, storage_path:, storage_result:)
        {
          "format" => FORMAT,
          "version" => VERSION,
          "backup_id" => backup_id,
          "created_at" => created_at.utc.iso8601(6),
          "release" => { "sha" => safe_release_sha(release_sha) },
          "database" => {
            "engine" => "postgresql",
            "dump_format" => "custom",
            "schema_version" => Integer(schema_version)
          },
          "artifacts" => {
            DATABASE_FILENAME => artifact_metadata(database_path, "postgresql_custom"),
            STORAGE_FILENAME => artifact_metadata(storage_path, "tar_gzip")
          },
          "aggregates" => {
            "storage_file_count" => storage_result.file_count,
            "storage_total_bytes" => storage_result.total_bytes
          }
        }
      end

      def self.sha256(path)
        Digest::SHA256.file(path).hexdigest
      end

      def self.artifact_metadata(path, media_type)
        {
          "sha256" => sha256(path),
          "bytes" => File.size(path),
          "type" => media_type
        }
      end
      private_class_method :artifact_metadata

      def self.safe_release_sha(value)
        sha = value.to_s
        sha.match?(/\A[0-9a-f]{7,64}\z/) ? sha : "unknown"
      end
      private_class_method :safe_release_sha
    end
  end
end
