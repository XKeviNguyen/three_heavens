require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/upload_budget_clock"

class SourceUploadActionTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper
  include UploadBudgetClock

  setup { sign_in_as users(:normal) }

  test "lost response at slot ten replays without work or charge and a new key is refused" do
    user = users(:normal)
    9.times { UploadBudget.consume(user:) }
    key = SecureRandom.hex(16)
    deliver(key)
    assert_response :created
    original = response.parsed_body
    assert_equal 10, UploadBudget.find_by!(user:).count
    extractor = SourceImports::TextExtractor.method(:call)
    SourceImports::TextExtractor.define_singleton_method(:call) { |**| raise "replay must not extract" }
    begin
      3.times do
        assert_no_difference([ "SourceImport.count", "ActiveStorage::Blob.count", "ActiveStorage::Attachment.count" ]) { deliver(key) }
        assert_response :created
        assert_equal original, response.parsed_body
        assert_equal 10, UploadBudget.find_by!(user:).count
      end
      deliver(SecureRandom.hex(16))
      assert_response :too_many_requests
      deliver(key, text: "Changed bytes")
      assert_response :unprocessable_content
      assert_equal "request_key_reused", response.parsed_body.fetch("code")
      assert_equal 10, UploadBudget.find_by!(user:).count
    ensure
      SourceImports::TextExtractor.singleton_class.define_method(:call, extractor.unbind)
    end
  end

  test "a failed extraction replays at the cap and unavailable imports never do new work" do
    user = users(:normal)
    9.times { UploadBudget.consume(user:) }
    key = SecureRandom.hex(16)
    bytes = "PK\x03\x04invalid".b
    2.times do
      post source_imports_path, params: { source_import: { request_key: key, source_file: uploaded_file(bytes, filename: "broken.docx") } }, headers: { "Accept" => "application/json" }
      assert_response :unprocessable_content
      assert_equal "malformed_docx", response.parsed_body.fetch("code")
      assert_equal 10, UploadBudget.find_by!(user:).count
    end
    assert_equal 1, user.source_imports.count
  end

  test "pending and expired same-key actions at a full budget remain unavailable" do
    user = users(:normal)
    key = SecureRandom.hex(16)
    deliver(key)
    imported = user.source_imports.sole
    9.times { UploadBudget.consume(user:) }
    [ { status: :pending }, { status: :ready, expires_at: 1.minute.ago } ].each do |attributes|
      imported.update!(attributes)
      assert_no_difference([ "SourceImport.count", "ActiveStorage::Blob.count" ]) { deliver(key) }
      assert_response :unprocessable_content
      assert_equal "import_unavailable", response.parsed_body.fetch("code")
      assert_equal 10, UploadBudget.find_by!(user:).count
    end
  end

  private

  def deliver(key, text: "Slot ten source")
    post source_imports_path, params: { source_import: { request_key: key, source_file: uploaded_file(text, filename: "ten.txt") } }, headers: { "Accept" => "application/json" }
  end
end
