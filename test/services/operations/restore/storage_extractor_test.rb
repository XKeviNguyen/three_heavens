require "test_helper"
require "rubygems/package"
require "zlib"

class Operations::Restore::StorageExtractorTest < ActiveSupport::TestCase
  test "extracts exact bytes into a new isolated destination" do
    Dir.mktmpdir("three-heavens-archive-") do |root|
      archive = File.join(root, "storage.tar.gz")
      write_archive(archive) do |tar|
        tar.mkdir("ab", 0o700)
        tar.mkdir("ab/cd", 0o700)
        tar.add_file_simple("ab/cd/opaque-key", 0o600, 5) { |file| file.write("bytes") }
      end
      destination = File.join(root, "restore")

      result = Operations::Restore::StorageExtractor.call(archive_path: archive, destination: destination)

      assert_equal 1, result.file_count
      assert_equal 5, result.total_bytes
      assert_equal "bytes", File.binread(File.join(destination, "ab", "cd", "opaque-key"))
      assert_equal 0o600, File.stat(File.join(destination, "ab", "cd", "opaque-key")).mode & 0o777
    end
  end

  # Stored uploads (PDF, DOCX, UTF-8 text) are arbitrary bytes. This round trip
  # uses the backup archiver and crosses the extractor's 1 MiB read chunk.
  test "restores every byte value of a stored object exactly" do
    bytes = (0..255).map(&:chr).join.b * 4200
    Dir.mktmpdir("three-heavens-binary-") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(File.join(source, "ab", "cd"))
      File.binwrite(File.join(source, "ab", "cd", "abcdefghijklmnopqrstuvwxyz"), bytes)
      archive = File.join(root, "storage.tar.gz")
      Operations::Backup::StorageArchive.create(source: Pathname.new(source).realpath, destination: Pathname.new(archive))
      destination = File.join(root, "restore")

      result = Operations::Restore::StorageExtractor.call(archive_path: archive, destination: destination)

      assert_equal bytes.bytesize, result.total_bytes
      assert_operator bytes.bytesize, :>, 1024 * 1024
      assert_equal bytes, File.binread(File.join(destination, "ab", "cd", "abcdefghijklmnopqrstuvwxyz"))
    end
  end

  test "rejects traversal absolute link and duplicate archive entries" do
    attacks = {
      traversal: ->(tar) { tar.add_file_simple("../escape", 0o600, 1) { |file| file.write("x") } },
      absolute: ->(tar) { tar.add_file_simple("/absolute", 0o600, 1) { |file| file.write("x") } },
      symlink: ->(tar) { tar.add_symlink("unsafe", "/etc/passwd", 0o777) },
      duplicate: lambda do |tar|
        2.times { tar.add_file_simple("duplicate", 0o600, 1) { |file| file.write("x") } }
      end
    }

    attacks.each do |name, writer|
      Dir.mktmpdir("three-heavens-#{name}-") do |root|
        archive = File.join(root, "storage.tar.gz")
        write_archive(archive, &writer)

        assert_raises(Operations::Restore::StorageExtractor::UnsafeArchive, name.to_s) do
          Operations::Restore::StorageExtractor.call(
            archive_path: archive,
            destination: File.join(root, "restore")
          )
        end
        assert_not File.exist?(File.join(root, "escape"))
      end
    end
  end

  test "refuses a non-empty restore destination" do
    Dir.mktmpdir("three-heavens-archive-") do |root|
      archive = File.join(root, "storage.tar.gz")
      write_archive(archive) { |tar| tar.add_file_simple("object", 0o600, 1) { |file| file.write("x") } }
      destination = File.join(root, "restore")
      FileUtils.mkdir_p(destination)
      File.write(File.join(destination, "existing"), "do not overwrite")

      assert_raises(Operations::Restore::StorageExtractor::UnsafeArchive) do
        Operations::Restore::StorageExtractor.call(archive_path: archive, destination: destination)
      end
      assert_equal "do not overwrite", File.read(File.join(destination, "existing"))
    end
  end

  private

  def write_archive(path)
    File.open(path, "wb") do |file|
      Zlib::GzipWriter.wrap(file) do |gzip|
        Gem::Package::TarWriter.new(gzip) { |tar| yield tar }
      end
    end
  end
end
