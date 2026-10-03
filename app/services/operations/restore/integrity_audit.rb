require "find"
require "pg"
require "set"

module Operations
  module Restore
    class IntegrityAudit
      class AuditFailed < StandardError; end

      BATCH_SIZE = 1_000
      SAFE_KEY = /\A[A-Za-z0-9_-]{16,255}\z/

      Result = Data.define(
        :blob_count,
        :attachment_count,
        :document_source_attachment_count,
        :source_import_staging_attachment_count,
        :expected_disk_objects,
        :found_disk_objects,
        :missing_disk_objects,
        :corrupt_disk_objects,
        :unreferenced_disk_objects,
        :critical_count,
        :warning_count,
        :schema_version
      ) do
        def successful?
          critical_count.zero?
        end
      end

      def self.call(database_url:, storage_path:, expected_schema_version: nil, connector: PG)
        new(
          database_url: database_url,
          storage_path: storage_path,
          expected_schema_version: expected_schema_version,
          connector: connector
        ).call
      end

      def initialize(database_url:, storage_path:, expected_schema_version: nil, connector: PG)
        @database_url = database_url
        @storage_path = Pathname.new(storage_path).realpath
        @expected_schema_version = expected_schema_version
        @connector = connector
      end

      def call
        connection = connector.connect(database_url)
        blob_count = scalar(connection, "SELECT COUNT(*) FROM active_storage_blobs")
        attachment_count = scalar(connection, "SELECT COUNT(*) FROM active_storage_attachments")
        document_count = attachment_count_for(connection, "Document", "source_file")
        source_import_count = attachment_count_for(connection, "SourceImport", "source_file")
        schema_version = current_schema_version(connection)
        critical_count = expected_schema_version && schema_version != expected_schema_version ? 1 : 0
        warning_count = 0
        found_count = 0
        missing_count = 0
        corrupt_count = 0
        last_id = 0

        loop do
          rows = connection.exec_params(
            "SELECT id, key, byte_size, checksum FROM active_storage_blobs WHERE id > $1 ORDER BY id LIMIT $2",
            [ last_id, BATCH_SIZE ]
          ).to_a
          break if rows.empty?

          blob_ids = rows.map { |row| Integer(row.fetch("id")) }
          attachment_types = attachment_types_for(connection, blob_ids)
          rows.each do |row|
            blob_id = Integer(row.fetch("id"))
            key = row.fetch("key")
            last_id = blob_id
            if valid_key?(key) && regular_disk_object?(key)
              if recorded_bytes?(key, Integer(row.fetch("byte_size")), row.fetch("checksum"))
                found_count += 1
                next
              end
              corrupt_count += 1
            else
              missing_count += 1
            end

            types = attachment_types.fetch(blob_id, Set.new)
            if types.include?([ "Document", "source_file" ]) || (types.any? && !types.include?([ "SourceImport", "source_file" ]))
              critical_count += 1
            else
              warning_count += 1
            end
          end
        end
        unreferenced_count, unsafe_entry_count = count_unreferenced(connection)
        warning_count += unreferenced_count
        critical_count += unsafe_entry_count

        Result.new(
          blob_count: blob_count,
          attachment_count: attachment_count,
          document_source_attachment_count: document_count,
          source_import_staging_attachment_count: source_import_count,
          expected_disk_objects: blob_count,
          found_disk_objects: found_count,
          missing_disk_objects: missing_count,
          corrupt_disk_objects: corrupt_count,
          unreferenced_disk_objects: unreferenced_count,
          critical_count: critical_count,
          warning_count: warning_count,
          schema_version: schema_version
        )
      rescue PG::Error
        raise AuditFailed, "restored database integrity queries failed"
      ensure
        connection&.close
      end

      private

      attr_reader :connector, :database_url, :expected_schema_version, :storage_path

      def scalar(connection, sql, parameters = [])
        Integer(connection.exec_params(sql, parameters).getvalue(0, 0))
      end

      def attachment_count_for(connection, record_type, name)
        scalar(
          connection,
          "SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = $1 AND name = $2",
          [ record_type, name ]
        )
      end

      def current_schema_version(connection)
        scalar(connection, "SELECT COALESCE(MAX(version::bigint), 0) FROM schema_migrations")
      end

      def attachment_types_for(connection, blob_ids)
        placeholders = blob_ids.each_index.map { |index| "$#{index + 1}" }.join(",")
        rows = connection.exec_params(
          "SELECT blob_id, record_type, name FROM active_storage_attachments WHERE blob_id IN (#{placeholders})",
          blob_ids
        )
        rows.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |row, result|
          result[Integer(row.fetch("blob_id"))] << [ row.fetch("record_type"), row.fetch("name") ]
        end
      end

      def valid_key?(key)
        SAFE_KEY.match?(key)
      end

      def disk_path(key)
        Operations::PathSafety.child!(storage_path, File.join(key[0..1], key[2..3], key))
      rescue Operations::PathSafety::UnsafePath
        Pathname.new("/nonexistent-three-heavens-storage-object")
      end

      def regular_disk_object?(key)
        first = storage_path.join(key[0..1])
        second = first.join(key[2..3])
        path = disk_path(key)
        [ first, second ].all? { |directory| directory.directory? && !directory.symlink? } &&
          path.exist? && !path.symlink? && path.lstat.file?
      rescue Errno::ENOENT
        false
      end

      # The object holds exactly the bytes Active Storage recorded at upload:
      # the same length and, when one was recorded, the same base64 MD5.
      def recorded_bytes?(key, byte_size, checksum)
        path = disk_path(key)
        return false unless path.size == byte_size
        return true if checksum.nil?

        digest = OpenSSL::Digest::MD5.new
        path.open("rb") do |file|
          buffer = "".b
          digest << buffer while file.read(1.megabyte, buffer)
        end
        ActiveSupport::SecurityUtils.secure_compare(digest.base64digest, checksum)
      end

      def count_unreferenced(connection)
        keys = []
        unreferenced = 0
        unsafe = 0
        flush = lambda do
          next if keys.empty?

          placeholders = keys.each_index.map { |index| "$#{index + 1}" }.join(",")
          existing = connection.exec_params(
            "SELECT key FROM active_storage_blobs WHERE key IN (#{placeholders})",
            keys
          ).column_values(0).to_set
          unreferenced += keys.count { |key| !existing.include?(key) }
          keys.clear
        end

        Find.find(storage_path.to_s) do |entry|
          next if entry == storage_path.to_s

          stat = File.lstat(entry)
          if stat.symlink? || (!stat.file? && !stat.directory?)
            unsafe += 1
            Find.prune if stat.directory?
          elsif stat.file?
            key = File.basename(entry)
            relative = Pathname.new(entry).relative_path_from(storage_path).to_s
            expected_relative = valid_key?(key) ? File.join(key[0..1], key[2..3], key) : nil
            if relative != expected_relative
              unreferenced += 1
              next
            end
            keys << key
            flush.call if keys.size >= BATCH_SIZE
          end
        end
        flush.call
        [ unreferenced, unsafe ]
      end
    end
  end
end
