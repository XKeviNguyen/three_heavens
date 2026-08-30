require "find"
require "rubygems/package"
require "zlib"

module Operations
  module Backup
    class StorageArchive
      class UnsafeStorage < StandardError; end

      Result = Data.define(:file_count, :total_bytes)

      def self.create(source:, destination:)
        new(source: source, destination: destination).create
      end

      def initialize(source:, destination:)
        @source = Pathname.new(source).realpath
        @destination = Pathname.new(destination)
      end

      def create
        raise UnsafeStorage, "storage root must be a directory" unless source.directory?
        raise UnsafeStorage, "storage root cannot be a symbolic link" if source.symlink?

        file_count = 0
        total_bytes = 0
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.binmode
          gzip = Zlib::GzipWriter.new(file)
          begin
            Gem::Package::TarWriter.new(gzip) do |tar|
              each_entry do |path, relative, stat|
                if stat.directory?
                  tar.mkdir(relative, stat.mode & 0o777)
                elsif stat.file?
                  file_count += 1
                  total_bytes += stat.size
                  tar.add_file_simple(relative, stat.mode & 0o777, stat.size) do |archive_file|
                    File.open(path, "rb") { |input| IO.copy_stream(input, archive_file) }
                  end
                else
                  raise UnsafeStorage, "storage contains an unsupported filesystem entry"
                end
              end
            end
            gzip.finish
          ensure
            gzip.close unless gzip.closed?
          end
          file.flush
          file.fsync
        end
        Result.new(file_count: file_count, total_bytes: total_bytes)
      rescue Errno::ELOOP
        raise UnsafeStorage, "storage contains an unsafe symbolic link"
      end

      private

      attr_reader :destination, :source

      def each_entry
        Find.find(source.to_s) do |entry|
          next if entry == source.to_s

          path = Pathname.new(entry)
          stat = path.lstat
          if stat.symlink?
            Find.prune if path.directory?
            raise UnsafeStorage, "storage contains a symbolic link"
          end
          relative = path.relative_path_from(source).to_s
          Operations::PathSafety.child!(source, relative)
          yield path, relative, stat
        end
      end
    end
  end
end
