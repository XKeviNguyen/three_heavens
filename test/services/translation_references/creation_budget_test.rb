require "test_helper"
require_relative "../../support/document_io_test_helper"
require_relative "../../support/translation_reference_test_helper"
require_relative "../../support/upload_budget_clock"

module TranslationReferences
  class CreationBudgetTest < ActiveSupport::TestCase
    include DocumentIoTestHelper
    include TranslationReferenceTestHelper
    include UploadBudgetClock

    test "same action Busy after first work replays without a second extraction or admission" do
      key = ReplayIdentity.issue
      calls = 0
      original = SourceImports::PdfExtractor.method(:call)
      SourceImports::PdfExtractor.define_singleton_method(:call) do |*|
        calls += 1
        raise SourceImports::Busy.new("pdf_busy", "PDF work is busy") if calls > 1

        "Resolved first side"
      end
      begin
        3.times do
          error = assert_raises(AuthoringAttributes::Busy) do
            Create.call(user: users(:normal), creation_key: key, attributes: file_pair)
          end
          assert error.work_consumed
          assert_equal "Resolved first side", error.resolved_attributes.fetch("source_text")
          assert_equal 1, UploadBudget.find_by!(user: users(:normal)).count
        end
        assert_equal 2, calls
        assert_equal 1, TranslationReferenceCreation.where(user: users(:normal), creation_key: key).count
        assert_equal 0, users(:normal).translation_references.count
      ensure
        SourceImports::PdfExtractor.singleton_class.define_method(:call, original.unbind)
      end
    end

    test "Busy before work refunds each same-key retry then a normal retry consumes once" do
      key = ReplayIdentity.issue
      original = SourceImports::PdfExtractor.method(:call)
      SourceImports::PdfExtractor.define_singleton_method(:call) { |*| raise SourceImports::Busy.new("pdf_busy", "PDF work is busy") }
      begin
        3.times do
          error = assert_raises(AuthoringAttributes::Busy) do
            Create.call(user: users(:normal), creation_key: key, attributes: file_pair)
          end
          assert_not error.work_consumed
          assert_equal 0, UploadBudget.find_by!(user: users(:normal)).count
          assert_equal 0, TranslationReferenceCreation.where(user: users(:normal), creation_key: key).count
        end
      ensure
        SourceImports::PdfExtractor.singleton_class.define_method(:call, original.unbind)
      end
      reference = Create.call(user: users(:normal), creation_key: key, attributes: file_pair)
      assert_equal 1, reference.revisions.count
      assert_equal 1, UploadBudget.find_by!(user: users(:normal)).count
      assert_equal reference, Create.call(user: users(:normal), creation_key: key, attributes: file_pair)
      assert_equal 1, UploadBudget.find_by!(user: users(:normal)).count
    end

    private

    def file_pair
      translation_reference_attributes(source_text: "", approved_translation: "").merge(
        source_file: uploaded_file(pdf_with_text("Source"), filename: "source.pdf", content_type: "application/pdf"),
        approved_translation_file: uploaded_file(pdf_with_text("Approved"), filename: "approved.pdf", content_type: "application/pdf")
      )
    end
  end
end
