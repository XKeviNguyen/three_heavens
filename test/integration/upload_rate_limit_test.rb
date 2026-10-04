require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/upload_budget_clock"

# All PDFs share one worker slot, and a 24 KB PDF can hold it for the whole
# 5-second parse limit. Each account has one budget of file-carrying requests
# across the upload forms, so one account looping uploads cannot keep
# everyone else's PDFs busy.
class UploadRateLimitTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper
  include UploadBudgetClock

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

    # The authoritative window uses PostgreSQL's clock, not Rails time travel.
    budget = UploadBudget.find_by!(user: users(:normal))
    budget.update!(window_id: budget.window_id - 1)
    post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    assert_response :created

    sign_out
    sign_in_as users(:other)
    post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    assert_response :created
    assert_equal 1, UploadBudget.find_by!(user: users(:normal)).count
  end

  test "reference uploads share the budget with source imports and a refused one keeps the form" do
    sign_in_as users(:normal)
    (BUDGET / 2).times do
      post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
      assert_response :created
    end
    (BUDGET - (BUDGET / 2)).times do |index|
      post translation_references_path, params: { translation_reference: reference_params("Reference #{index}") }
      assert_response :redirect
    end

    assert_no_difference "TranslationReference.count" do
      post translation_references_path, params: { translation_reference: reference_params("One too many") }
    end
    assert_response :too_many_requests
    assert_select "input[name='translation_reference[title]'][value='One too many']"
    assert_select "section[aria-labelledby='reference-errors-heading'] li", text: /uploaded many files/
    post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    assert_response :too_many_requests
  end

  test "text-only reference edits never count toward the upload budget" do
    sign_in_as users(:normal)
    post translation_references_path, params: { translation_reference: text_reference_params("Pasted", "Version 1") }
    reference = TranslationReference.order(:id).last

    (BUDGET + 2).times do |index|
      patch translation_reference_path(reference), params: { translation_reference: text_reference_params("Pasted", "Version #{index + 2}")
        .merge(expected_version: reference.reload.current_revision.version.to_s) }
      assert_redirected_to translation_reference_path(reference)
    end
    post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    assert_response :created
  end

  test "a busy answer does not spend the budget" do
    sign_in_as users(:normal)
    busy = SourceImports::Busy.new("pdf_busy", SourceImports::PdfExtractor::MESSAGES.fetch("pdf_busy"))
    original = SourceImports::PdfExtractor.method(:call)
    SourceImports::PdfExtractor.define_singleton_method(:call) { |*| raise busy }
    begin
      (BUDGET + 2).times do
        post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
        assert_response :service_unavailable
        assert_equal "5", response.headers["Retry-After"]
        assert_equal 0, UploadBudget.find_by!(user: users(:normal)).count
      end
    ensure
      SourceImports::PdfExtractor.singleton_class.define_method(:call, original.unbind)
    end

    post source_imports_path, params: import_params, headers: { "Accept" => "application/json" }
    assert_response :created
  end

  test "reference Busy before extraction refunds and preserves submitted values" do
    sign_in_as users(:normal)
    with_pdf_busy_after(0) do
      (BUDGET + 1).times do
        assert_no_difference [ "TranslationReference.count", "TranslationReferenceRevision.count" ] do
          post translation_references_path, params: { translation_reference: reference_params("Still submitted") }
        end
        assert_response :service_unavailable
        assert_equal "5", response.headers["Retry-After"]
        assert_equal 0, UploadBudget.find_by!(user: users(:normal)).count
        assert_select "input[name='translation_reference[title]'][value='Still submitted']"
      end
    end
  end

  test "reference Busy after first extraction retains the charge and resolved text" do
    sign_in_as users(:normal)
    with_pdf_busy_after(1) do
      assert_no_difference [ "TranslationReference.count", "TranslationReferenceRevision.count" ] do
        post translation_references_path, params: { translation_reference: reference_params("Partial") }
      end
    end
    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_equal 1, UploadBudget.find_by!(user: users(:normal)).count
    assert_select "textarea[name='translation_reference[source_text]']", text: "Extracted source"
  end

  test "reference update Busy refunds without creating a revision and preserves the version" do
    sign_in_as users(:normal)
    post translation_references_path, params: { translation_reference: text_reference_params("Original", "Original source") }
    reference = TranslationReference.order(:id).last
    version = reference.current_revision.version
    with_pdf_busy_after(0) do
      assert_no_difference "TranslationReferenceRevision.count" do
        patch translation_reference_path(reference), params: { translation_reference: reference_params("Retry edit").merge(expected_version: version.to_s) }
      end
    end
    assert_response :service_unavailable
    assert_equal "5", response.headers["Retry-After"]
    assert_equal 0, UploadBudget.find_by!(user: users(:normal)).count
    assert_select "input[name='translation_reference[expected_version]'][value='#{version}']"
  end

  private

  def with_pdf_busy_after(successes)
    calls = 0
    original = SourceImports::PdfExtractor.method(:call)
    SourceImports::PdfExtractor.define_singleton_method(:call) do |*|
      calls += 1
      raise SourceImports::Busy.new("pdf_busy", SourceImports::PdfExtractor::MESSAGES.fetch("pdf_busy")) if calls > successes

      "Extracted source"
    end
    yield
  ensure
    SourceImports::PdfExtractor.singleton_class.define_method(:call, original.unbind)
  end

  def import_params
    { source_import: { request_key: SecureRandom.hex(16), source_file: uploaded_file(pdf_with_text("Source"), filename: "source.pdf", content_type: "application/pdf") } }
  end

  def text_reference_params(title, source_text)
    { title:, source_language: "Vietnamese", target_language: "Japanese", source_text:, approved_translation: "Approved" }
  end

  def reference_params(title)
    { title:, source_language: "Vietnamese", target_language: "Japanese",
      source_file: uploaded_file(pdf_with_text("Source"), filename: "source.pdf", content_type: "application/pdf"),
      approved_translation_file: uploaded_file(pdf_with_text("Approved"), filename: "approved.pdf", content_type: "application/pdf") }
  end
end
