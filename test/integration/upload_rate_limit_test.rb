require "test_helper"
require_relative "../support/document_io_test_helper"

# All PDFs share one worker slot, and a 24 KB PDF can hold it for the whole
# 5-second parse limit. Each account's uploads are budgeted per form, so one
# account looping uploads cannot keep everyone else's PDFs busy.
class UploadRateLimitTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper

  BUDGET = SourceImports::Limits::UPLOADS_PER_WINDOW

  test "source imports stop at the account's budget, with a retry time, and other accounts keep theirs" do
    sign_in_as users(:normal)
    BUDGET.times do
      post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
      assert_response :created
    end

    assert_no_difference "SourceImport.count" do
      post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    end
    assert_response :too_many_requests
    assert_equal SourceImports::Limits::UPLOAD_WINDOW.to_i.to_s, response.headers["Retry-After"]
    assert_match "uploaded many files", response.parsed_body.fetch("error")

    post source_imports_path, params: import_params
    assert_response :too_many_requests
    assert_select "[role='alert']", text: /uploaded many files/

    travel(SourceImports::Limits::UPLOAD_WINDOW + 1.second) do
      sign_in_as users(:normal)
      post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
      assert_response :created
    end

    sign_out
    sign_in_as users(:other)
    post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    assert_response :created
  end

  test "translation reference uploads have their own budget and keep the form on refusal" do
    sign_in_as users(:normal)
    BUDGET.times do |index|
      post translation_references_path, params: { translation_reference: reference_params("Reference #{index}") }
      assert_response :redirect
    end

    assert_no_difference "TranslationReference.count" do
      post translation_references_path, params: { translation_reference: reference_params("One too many") }
    end
    assert_response :too_many_requests
    assert_select "input[name='translation_reference[title]'][value='One too many']"
    assert_select "section[aria-labelledby='reference-errors-heading'] li", text: /uploaded many files/
  end

  private

  def import_params
    { source_import: { request_key: SecureRandom.hex(16), source_file: uploaded_file(pdf_with_text("Source"), filename: "source.pdf", content_type: "application/pdf") } }
  end

  def reference_params(title)
    { title:, source_language: "Vietnamese", target_language: "Japanese",
      source_file: uploaded_file(pdf_with_text("Source"), filename: "source.pdf", content_type: "application/pdf"),
      approved_translation_file: uploaded_file(pdf_with_text("Approved"), filename: "approved.pdf", content_type: "application/pdf") }
  end
end
