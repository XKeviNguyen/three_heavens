require "json"

module Operations
  module Restore
    class BundleVerifier
      class InvalidBundle < StandardError; end

      MAX_MANIFEST_BYTES = 65_536
      MAX_ARTIFACT_BYTES = 10 * 1024 * 1024 * 1024 * 1024
      MAX_STORAGE_FILE_COUNT = 1_000_000_000
      TOP_LEVEL_KEYS = %w[format version backup_id created_at release database artifacts aggregates].freeze
      RELEASE_KEYS = %w[sha].freeze
      DATABASE_KEYS = %w[engine dump_format schema_version].freeze
      ARTIFACT_KEYS = %w[sha256 bytes type].freeze
      AGGREGATE_KEYS = %w[storage_file_count storage_total_bytes].freeze

      Result = Data.define(:path, :manifest)

      def self.call(bundle_path)
        new(bundle_path).call
      end

      def initialize(bundle_path)
        @bundle_path_value = bundle_path
      end

      def call
        bundle_path = Operations::PathSafety.prepare_root!(bundle_path_value)
        raise InvalidBundle, "partial bundle paths are not valid" if bundle_path.basename.to_s.start_with?(".partial-")

        validate_bundle_entries!(bundle_path)
        manifest_path = safe_regular_file!(bundle_path, Operations::Backup::Manifest::MANIFEST_FILENAME)
        marker_path = safe_regular_file!(bundle_path, Operations::Backup::Manifest::COMPLETION_FILENAME)
        raise InvalidBundle, "manifest is too large" if manifest_path.size > MAX_MANIFEST_BYTES

        manifest = JSON.parse(manifest_path.binread, max_nesting: 12)
        validate_manifest!(manifest)
        validate_marker!(manifest_path, marker_path)
        validate_artifacts!(bundle_path, manifest)
        Result.new(path: bundle_path, manifest: deep_freeze(manifest))
      rescue JSON::ParserError
        raise InvalidBundle, "manifest is malformed"
      rescue Operations::PathSafety::UnsafePath => error
        raise InvalidBundle, error.message
      end

      private

      attr_reader :bundle_path_value

      def safe_regular_file!(root, filename)
        path = Operations::PathSafety.child!(root, filename)
        raise InvalidBundle, "required bundle file is missing" unless path.exist?
        raise InvalidBundle, "bundle files cannot be symbolic links" if path.symlink?
        raise InvalidBundle, "bundle artifact is not a regular file" unless path.file?

        path
      end

      def validate_bundle_entries!(bundle_path)
        expected = [
          Operations::Backup::Manifest::MANIFEST_FILENAME,
          Operations::Backup::Manifest::DATABASE_FILENAME,
          Operations::Backup::Manifest::STORAGE_FILENAME,
          Operations::Backup::Manifest::COMPLETION_FILENAME
        ].sort
        actual = bundle_path.children.map { |path| path.basename.to_s }.sort
        raise InvalidBundle, "bundle contains unexpected entries" unless actual == expected
      end

      def validate_manifest!(manifest)
        require_hash_keys!(manifest, TOP_LEVEL_KEYS)
        raise InvalidBundle, "unsupported bundle format" unless manifest["format"] == Operations::Backup::Manifest::FORMAT
        raise InvalidBundle, "unsupported bundle version" unless manifest["version"] == Operations::Backup::Manifest::VERSION
        raise InvalidBundle, "invalid backup ID" unless manifest["backup_id"].to_s.match?(/\A[0-9]{8}T[0-9]{6}Z-[0-9a-f]{24}\z/)
        validate_timestamp!(manifest["created_at"])
        validate_release!(manifest["release"])
        validate_database!(manifest["database"])
        validate_artifact_metadata!(manifest["artifacts"])
        validate_aggregates!(manifest["aggregates"])
      end

      def validate_timestamp!(value)
        parsed = Time.iso8601(value.to_s)
        raise InvalidBundle, "creation timestamp must be UTC" unless value.end_with?("Z") && parsed.utc?
      rescue ArgumentError
        raise InvalidBundle, "invalid creation timestamp"
      end

      def validate_release!(release)
        require_hash_keys!(release, RELEASE_KEYS)
        sha = release["sha"]
        return if sha == "unknown" || sha.to_s.match?(/\A[0-9a-f]{7,64}\z/)

        raise InvalidBundle, "invalid release metadata"
      end

      def validate_database!(database)
        require_hash_keys!(database, DATABASE_KEYS)
        unless database["engine"] == "postgresql" && database["dump_format"] == "custom"
          raise InvalidBundle, "unsupported database dump metadata"
        end
        bounded_integer!(database["schema_version"], maximum: 9_999_999_999_999_999)
      end

      def validate_artifact_metadata!(artifacts)
        require_hash_keys!(artifacts, Operations::Backup::Manifest::ARTIFACT_FILENAMES)
        expected_types = {
          Operations::Backup::Manifest::DATABASE_FILENAME => "postgresql_custom",
          Operations::Backup::Manifest::STORAGE_FILENAME => "tar_gzip"
        }
        artifacts.each do |filename, metadata|
          require_hash_keys!(metadata, ARTIFACT_KEYS)
          raise InvalidBundle, "invalid artifact checksum" unless metadata["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
          bounded_integer!(metadata["bytes"], maximum: MAX_ARTIFACT_BYTES)
          raise InvalidBundle, "invalid artifact type" unless metadata["type"] == expected_types.fetch(filename)
        end
      end

      def validate_aggregates!(aggregates)
        require_hash_keys!(aggregates, AGGREGATE_KEYS)
        bounded_integer!(aggregates["storage_file_count"], maximum: MAX_STORAGE_FILE_COUNT)
        bounded_integer!(aggregates["storage_total_bytes"], maximum: MAX_ARTIFACT_BYTES)
      end

      def validate_marker!(manifest_path, marker_path)
        marker = marker_path.binread
        expected = "#{Operations::Backup::Manifest.sha256(manifest_path)}\n"
        raise InvalidBundle, "completion marker does not match manifest" unless ActiveSupport::SecurityUtils.secure_compare(marker, expected)
      end

      def validate_artifacts!(bundle_path, manifest)
        manifest.fetch("artifacts").each do |filename, metadata|
          path = safe_regular_file!(bundle_path, filename)
          raise InvalidBundle, "artifact size mismatch" unless path.size == metadata.fetch("bytes")
          checksum = Operations::Backup::Manifest.sha256(path)
          unless ActiveSupport::SecurityUtils.secure_compare(checksum, metadata.fetch("sha256"))
            raise InvalidBundle, "artifact checksum mismatch"
          end
        end
      end

      def require_hash_keys!(value, exact_keys)
        unless value.is_a?(Hash) && value.keys.sort == exact_keys.sort
          raise InvalidBundle, "manifest shape is invalid"
        end
      end

      def bounded_integer!(value, maximum:)
        unless value.is_a?(Integer) && value.between?(0, maximum)
          raise InvalidBundle, "manifest integer is outside its allowed range"
        end
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
        when Array
          value.each { |nested| deep_freeze(nested) }
        end
        value.freeze
      end
    end
  end
end
