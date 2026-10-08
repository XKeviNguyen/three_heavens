require "rubygems/package"
require "set"
require "zlib"

module Operations
  module Restore
    class StorageExtractor
      class UnsafeArchive < StandardError; end

      MAX_ENTRIES = 10_000_000
      MAX_ENTRY_BYTES = 1024 * 1024 * 1024 * 1024
      MAX_TOTAL_BYTES = 10 * 1024 * 1024 * 1024 * 1024

      Result = Data.define(:file_count, :total_bytes)

      def self.call(archive_path:, destination:)
        new(archive_path: archive_path, destination: destination).call
      end

      def self.validate(archive_path:)
        new(archive_path: archive_path, destination: nil).validate
      end

      def self.prepare_destination!(destination:)
        new(archive_path: nil, destination: destination).send(:prepare_empty_destination!)
      end

      def initialize(archive_path:, destination:)
        @archive_path = Pathname.new(archive_path) if archive_path
        @destination_value = destination
      end

      def call
        destination = prepare_empty_destination!
        scan_archive do |entry, relative|
          path = Operations::PathSafety.child!(destination, relative)
          entry.directory? ? create_directory!(path) : write_file!(entry, path)
        end
      end

      def validate
        scan_archive
      end

      private

      attr_reader :archive_path, :destination_value

      def scan_archive
        seen = Set.new
        file_count = 0
        total_bytes = 0
        entry_count = 0

        File.open(archive_path, "rb") do |archive_file|
          Zlib::GzipReader.wrap(archive_file) do |gzip|
            Gem::Package::TarReader.new(gzip) do |tar|
              tar.each do |entry|
                entry_count += 1
                raise UnsafeArchive, "storage archive contains too many entries" if entry_count > MAX_ENTRIES

                relative = validate_entry_name!(entry.full_name)
                raise UnsafeArchive, "storage archive contains duplicate entries" unless seen.add?(relative)
                unless entry.directory? || entry.file?
                  raise UnsafeArchive, "links and special archive entries are not allowed"
                end

                if entry.file?
                  raise UnsafeArchive, "storage archive entry is too large" if entry.header.size > MAX_ENTRY_BYTES

                  file_count += 1
                  total_bytes += entry.header.size
                  raise UnsafeArchive, "storage archive expands beyond its allowed size" if total_bytes > MAX_TOTAL_BYTES
                end
                yield entry, relative if block_given?
              end
            end
          end
        end
        Result.new(file_count: file_count, total_bytes: total_bytes)
      rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError
        raise UnsafeArchive, "storage archive is malformed"
      end

      def prepare_empty_destination!
        path = Pathname.new(destination_value.to_s)
        raise UnsafeArchive, "restore storage destination is required" if destination_value.to_s.strip.empty?
        raise UnsafeArchive, "restore storage destination must be absolute" unless path.absolute?
        destination = Operations::PathSafety.prepare_root!(path, create: true, forbidden: [ Rails.root, live_storage_path ])
        raise UnsafeArchive, "restore storage destination must be empty" if destination.children.any?

        destination
      rescue Operations::PathSafety::UnsafePath => error
        raise UnsafeArchive, error.message
      end

      def live_storage_path
        service = ActiveStorage::Blob.service
        Pathname.new(service.root.to_s).expand_path if service.respond_to?(:root)
      end

      def validate_entry_name!(name)
        raise UnsafeArchive, "archive path is invalid" unless name.is_a?(String) && name.bytesize.between?(1, 4096)
        raise UnsafeArchive, "archive path contains a null byte" if name.include?("\0")

        path = Pathname.new(name)
        if path.absolute? || path.each_filename.any? { |component| component == ".." } || path.cleanpath.to_s == "."
          raise UnsafeArchive, "archive path traversal is not allowed"
        end
        path.cleanpath.to_s
      end

      def create_directory!(path)
        ensure_safe_parents!(path.parent)
        if path.exist? || path.symlink?
          raise UnsafeArchive, "archive directory collides with an existing entry" unless path.directory? && !path.symlink?
        else
          Dir.mkdir(path, 0o700)
        end
      end

      def write_file!(entry, path)
        ensure_safe_parents!(path.parent)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |output|
          # Stored objects are arbitrary bytes; text mode would transcode them.
          output.binmode
          while (chunk = entry.read(1024 * 1024)).present?
            output.write(chunk)
          end
          output.flush
          output.fsync
        end
      rescue Errno::EEXIST
        raise UnsafeArchive, "archive file collides with an existing entry"
      end

      def ensure_safe_parents!(path)
        missing = []
        current = path
        until current.exist?
          missing << current
          current = current.parent
        end
        raise UnsafeArchive, "archive parent is a symbolic link" if current.symlink?
        missing.reverse_each { |directory| Dir.mkdir(directory, 0o700) }
      end
    end
  end
end
