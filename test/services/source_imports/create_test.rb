require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class CreateTest < ActiveSupport::TestCase
    include DocumentIoTestHelper

    test "creates ready TXT provenance with actual byte size SHA and private attachment" do
      source_import = Create.call(
        user: users(:normal),
        request_key: SecureRandom.hex(16),
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

      assert Create.call(user: users(:normal), upload:, request_key: SecureRandom.hex(16)).ready?
    end

    test "rejects advertised oversize before reading content" do
      upload = Object.new
      upload.define_singleton_method(:size) { Limits::MAX_UPLOAD_BYTES + 1 }
      upload.define_singleton_method(:read) { raise "must not read" }
      upload.define_singleton_method(:rewind) { }

      error = assert_raises(Error) { Create.call(user: users(:normal), upload:, request_key: SecureRandom.hex(16)) }
      assert_equal "file_too_large", error.code
    end

    test "persists only a sanitized failure for malformed DOCX" do
      malformed = zip_entries("placeholder.txt" => "not a word package")
      error = assert_raises(Error) do
        Create.call(
          user: users(:normal),
          request_key: SecureRandom.hex(16),
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
        request_key: SecureRandom.hex(16),
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
        request_key: SecureRandom.hex(16),
        upload: uploaded_file(build_docx, filename: "source.docx", content_type: "application/x-zip-compressed")
      )

      assert source_import.ready?
      assert_equal "docx", source_import.imported_format

      malformed = zip_entries("placeholder.txt" => "not a word package")
      error = assert_raises(Error) do
        Create.call(
          user: users(:normal),
          request_key: SecureRandom.hex(16),
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
          request_key: SecureRandom.hex(16),
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

    test "a replayed upload action returns its import without storing another record or blob" do
      key = SecureRandom.hex(16)
      first = nil
      assert_difference stored_counts, 1 do
        first = Create.call(user: users(:normal), upload: uploaded_file("Replayed source", filename: "replay.txt"), request_key: key)
        2.times do
          replay = Create.call(user: users(:normal), upload: uploaded_file("Replayed source", filename: "replay.txt"), request_key: key)
          assert_equal first.id, replay.id
        end
      end
      assert_equal key, first.request_key
    end

    test "a new upload action of the same file is a separate import" do
      imports = 2.times.map do
        Create.call(user: users(:normal), upload: uploaded_file("Same bytes", filename: "same.txt"), request_key: SecureRandom.hex(16))
      end

      assert_equal 2, imports.map(&:id).uniq.size
      assert_equal 2, imports.map { it.source_file.blob_id }.uniq.size
    end

    test "a replay carrying a different file is refused without storing it" do
      key = SecureRandom.hex(16)
      Create.call(user: users(:normal), upload: uploaded_file("Original", filename: "original.txt"), request_key: key)

      [ [ "Different bytes", "original.txt" ], [ "Original", "renamed.txt" ] ].each do |content, filename|
        assert_no_difference stored_counts do
          error = assert_raises(Error) do
            Create.call(user: users(:normal), upload: uploaded_file(content, filename:), request_key: key)
          end
          assert_equal "request_key_reused", error.code
        end
      end
    end

    test "a replayed failed extraction reports the original failure without another record" do
      key = SecureRandom.hex(16)
      upload = -> { uploaded_file(build_docx(document_xml: "not valid XML"), filename: "broken.docx", content_type: Detector::DOCX_MIME) }
      first = assert_raises(Error) { Create.call(user: users(:normal), upload: upload.call, request_key: key) }

      assert_no_difference stored_counts do
        replay = assert_raises(Error) { Create.call(user: users(:normal), upload: upload.call, request_key: key) }
        assert_equal [ first.code, first.source_import.id ], [ replay.code, replay.source_import.id ]
      end
    end

    test "a replay after the import expired is refused rather than reused" do
      key = SecureRandom.hex(16)
      source_import = Create.call(user: users(:normal), upload: uploaded_file("Expiring", filename: "expiring.txt"), request_key: key)
      source_import.update!(expires_at: 1.minute.ago)

      error = assert_raises(Error) do
        Create.call(user: users(:normal), upload: uploaded_file("Expiring", filename: "expiring.txt"), request_key: key)
      end
      assert_equal "import_unavailable", error.code
    end

    test "request keys are scoped to their owner" do
      key = SecureRandom.hex(16)
      mine = Create.call(user: users(:normal), upload: uploaded_file("Shared key", filename: "shared.txt"), request_key: key)
      theirs = Create.call(user: users(:other), upload: uploaded_file("Shared key", filename: "shared.txt"), request_key: key)

      assert_not_equal mine.id, theirs.id
      assert_equal users(:other).id, theirs.user_id
    end

    test "a failure inside the transaction leaves no record, blob, attachment, or stored file" do
      uploads = count_storage_uploads
      ActiveRecord::Base.connection.execute(<<~SQL)
        ALTER TABLE active_storage_attachments
        ADD CONSTRAINT reject_source_import_attachment CHECK (record_type <> 'SourceImport')
      SQL

      assert_no_difference stored_counts do
        assert_raises(ActiveRecord::StatementInvalid) do
          Create.call(user: users(:normal), upload: uploaded_file("Rolled back", filename: "rollback.txt"), request_key: SecureRandom.hex(16))
        end
      end
      assert_equal 0, uploads.call
    ensure
      restore_storage_uploads
    end

    test "a storage write failure after commit removes the import and its blob" do
      service = ActiveStorage::Blob.service
      service.define_singleton_method(:upload) { |*| raise IOError, "synthetic storage outage" }
      key = SecureRandom.hex(16)

      assert_no_difference stored_counts do
        assert_raises(IOError) do
          Create.call(user: users(:normal), upload: uploaded_file("Unstored", filename: "unstored.txt"), request_key: key)
        end
      end
      restore_storage_uploads

      retried = Create.call(user: users(:normal), upload: uploaded_file("Unstored", filename: "unstored.txt"), request_key: key)
      assert retried.available?
      assert retried.source_file.blob.service.exist?(retried.source_file.blob.key)
    ensure
      restore_storage_uploads
    end

    private

    def stored_counts
      [ -> { SourceImport.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ]
    end

    def count_storage_uploads
      count = 0
      ActiveStorage::Blob.service.define_singleton_method(:upload) do |*arguments, **options|
        count += 1
        super(*arguments, **options)
      end
      -> { count }
    end

    def restore_storage_uploads
      singleton = ActiveStorage::Blob.service.singleton_class
      singleton.remove_method(:upload) if singleton.method_defined?(:upload, false)
    end

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
