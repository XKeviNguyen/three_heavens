require "test_helper"
require_relative "../../support/document_io_test_helper"

class TranslationReferences::AuthoringAttributesTest < ActiveSupport::TestCase
  include DocumentIoTestHelper

  test "shared upload path retains TXT MD and DOCX protections and never starts AI work" do
    valid_docx = build_docx(document_xml: basic_document_xml("<w:p><w:r><w:t>Exact DOCX</w:t></w:r></w:p>"))
    invalid_cases = [
      uploaded_file(build_docx(entries: { "word/vbaProject.bin" => "macro" }), filename: "macro.docx"),
      uploaded_file(build_docx(entries: { "word/media/repetition.bin" => "a" * 2.megabytes }), filename: "bomb.docx"),
      uploaded_file("PK\x03\x04garbage".b, filename: "bad.docx"),
      uploaded_file(build_docx, filename: "wrong.txt")
    ]

    assert_no_difference [ -> { TranslationRun.count }, -> { ActiveJob::Base.queue_adapter.enqueued_jobs.size } ] do
      values = TranslationReferences::AuthoringAttributes.call(
        "title" => "Upload",
        "source_language" => "Vietnamese",
        "target_language" => "Japanese",
        "source_file" => uploaded_file(valid_docx, filename: "source.docx"),
        "approved_translation_file" => uploaded_file("# Approved", filename: "approved.md")
      )
      assert_equal "Exact DOCX", values.fetch("source_text")
      assert_equal "# Approved", values.fetch("approved_translation")

      invalid_cases.each do |upload|
        assert_raises TranslationReferences::AuthoringAttributes::Error do
          TranslationReferences::AuthoringAttributes.call(
            "source_file" => upload,
            "approved_translation" => "Approved"
          )
        end
      end
    end
  end

  test "advertised and bounded upload limits are enforced" do
    oversized = Data.define(:size, :original_filename) do
      def read(*) = raise("must reject before reading")
      def rewind = nil
    end.new(SourceImports::Limits::MAX_UPLOAD_BYTES + 1, "large.txt")

    error = assert_raises TranslationReferences::AuthoringAttributes::Error do
      TranslationReferences::AuthoringAttributes.call(
        "source_file" => oversized,
        "approved_translation" => "Approved"
      )
    end
    assert_includes error.message, "10 MiB limit"
  end
end
