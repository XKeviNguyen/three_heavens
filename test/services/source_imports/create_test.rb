require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class CreateTest < ActiveSupport::TestCase
    include DocumentIoTestHelper

    test "creates ready TXT provenance with actual byte size SHA and private attachment" do
      source_import = Create.call(
        user: users(:normal),
        upload: uploaded_file("\xEF\xBB\xBFText\r\n日本語".b, filename: "..\\sermon.txt", content_type: "text/plain")
      )

      assert source_import.ready?
      assert_equal "sermon.txt", source_import.original_filename
      assert_equal "Text\n日本語", source_import.extracted_text
      assert_equal "txt", source_import.imported_format
      assert_equal "text/plain", source_import.detected_content_type
      assert_equal Digest::SHA256.hexdigest("\xEF\xBB\xBFText\r\n日本語".b), source_import.sha256
      assert source_import.source_file.attached?
      assert_equal source_import.byte_size, source_import.source_file.byte_size
      assert_in_delta 24.hours.from_now, source_import.expires_at, 5.seconds
    end

    test "accepts an advertised size exactly at the upload boundary and verifies actual bytes" do
      upload = uploaded_file("short source", filename: "source.txt", content_type: "text/plain")
      upload.define_singleton_method(:size) { Limits::MAX_UPLOAD_BYTES }

      assert Create.call(user: users(:normal), upload:).ready?
    end

    test "rejects advertised oversize before reading content" do
      upload = Object.new
      upload.define_singleton_method(:size) { Limits::MAX_UPLOAD_BYTES + 1 }
      upload.define_singleton_method(:read) { raise "must not read" }
      upload.define_singleton_method(:rewind) { }

      error = assert_raises(Error) { Create.call(user: users(:normal), upload:) }
      assert_equal "file_too_large", error.code
    end

    test "persists only a sanitized failure for malformed DOCX" do
      malformed = zip_entries("placeholder.txt" => "not a word package")
      error = assert_raises(Error) do
        Create.call(
          user: users(:normal),
          upload: uploaded_file(malformed, filename: "broken.docx", content_type: Detector::DOCX_MIME)
        )
      end

      source_import = error.source_import
      assert_equal "malformed_docx", error.code
      assert source_import.failed?
      assert_equal "malformed_docx", source_import.failure_code
      assert_equal "The selected file is not a valid DOCX document.", source_import.failure_message
      assert_not_includes source_import.failure_message, "placeholder.txt"
      assert_nil source_import.extracted_text
      assert source_import.source_file.attached?
    end

    test "imports DOCX through the same normalizer" do
      source_import = Create.call(
        user: users(:normal),
        upload: uploaded_file(build_docx, filename: "source.docx", content_type: Detector::DOCX_MIME)
      )

      assert source_import.ready?
      assert_equal "docx", source_import.imported_format
      assert_includes source_import.extracted_text, "Faith & hope — 信仰"
      assert_includes source_import.extracted_text, "Cell 1\tCell 2"
    end

    test "accepts generic x-zip-compressed DOCX uploads only after package validation" do
      source_import = Create.call(
        user: users(:normal),
        upload: uploaded_file(build_docx, filename: "source.docx", content_type: "application/x-zip-compressed")
      )

      assert source_import.ready?
      assert_equal "docx", source_import.imported_format

      malformed = zip_entries("placeholder.txt" => "not a word package")
      error = assert_raises(Error) do
        Create.call(
          user: users(:normal),
          upload: uploaded_file(malformed, filename: "broken.docx", content_type: "application/x-zip-compressed")
        )
      end
      assert_equal "malformed_docx", error.code
    end

    test "bounds long supported filenames by characters while preserving their extensions" do
      cases = [
        [ "a" * 300 + ".txt", "Text source", "text/plain", ".txt" ],
        [ "b" * 300 + ".md", "# Markdown source", "text/markdown", ".md" ],
        [ "c" * 300 + ".docx", build_docx, Detector::DOCX_MIME, ".docx" ],
        [ "文" * 300 + ".txt", "Unicode source", "text/plain", ".txt" ]
      ]

      cases.each do |filename, content, content_type, extension|
        source_import = Create.call(
          user: users(:normal),
          upload: uploaded_file(content, filename:, content_type:)
        )

        assert source_import.ready?
        assert_equal Limits::MAX_ORIGINAL_FILENAME_CHARACTERS, source_import.original_filename.length
        assert source_import.original_filename.end_with?(extension)
        assert_equal source_import.original_filename, source_import.source_file.filename.to_s
      end

      unicode_import = SourceImport.order(:id).last
      assert_match(/\A文+\.txt\z/, unicode_import.original_filename)
      assert unicode_import.original_filename.valid_encoding?
    end

    private

    def zip_entries(entries)
      buffer = Zip::OutputStream.write_buffer do |zip|
        entries.each do |name, contents|
          zip.put_next_entry(name)
          zip.write(contents)
        end
      end
      buffer.rewind
      buffer.read
    end
  end
end
