require "test_helper"
require_relative "../support/process_barrier"
require_relative "../support/upload_budget_clock"
require_relative "../support/document_io_test_helper"

class UploadBudgetConcurrencyTest < ActionDispatch::IntegrationTest
  include ProcessBarrier
  include UploadBudgetClock
  include DocumentIoTestHelper
  self.use_transactional_tests = false

  test "simultaneous same-account HTTP uploads cannot bypass the shared budget" do
    user = users(:normal)
    original_import_ids = SourceImport.pluck(:id)
    original_reference_ids = TranslationReference.pluck(:id)
    UploadBudget.where(user:).delete_all
    sign_in_as user
    authenticated_cookies = cookies.to_hash
    statuses = in_processes(24) do |index|
      client = ActionDispatch::Integration::Session.new(Rails.application)
      authenticated_cookies.each { |name, value| client.cookies[name] = value }
      upload = uploaded_file("Source #{index}", filename: "source.txt", content_type: "text/plain")
      if index.even?
        client.post source_imports_path, params: { source_import: { request_key: ReplayIdentity.issue, source_file: upload } },
                    headers: { "Accept" => "application/json" }
      else
        client.post translation_references_path, params: { translation_reference: {
          creation_key: ReplayIdentity.issue, title: "Concurrent #{index}", source_language: "Vietnamese", target_language: "Japanese",
          source_file: upload, approved_translation: "Approved"
        } }
      end
      [ client.response.status, client.response.location ]
    end
    assert_equal SourceImports::Limits::UPLOADS_PER_WINDOW, statuses.count { |status, location| status == 201 || (status == 302 && location.include?("/translation_references/")) }, statuses.inspect
    assert_equal 14, statuses.count { |status, _| status == 429 }, statuses.inspect
    assert_equal 10, UploadBudget.find_by!(user:).count
  ensure
    sign_out if signed_in_user_id
    SourceImport.where.not(id: original_import_ids).destroy_all if original_import_ids
    if original_reference_ids
      # These rows were committed by child processes, outside Rails' test
      # transaction. Remove only this test's history using the established
      # fixture-cleanup boundary; production history remains sealed.
      TranslationReferenceCreation.where(translation_reference_id: TranslationReference.where.not(id: original_reference_ids).select(:id)).delete_all
      mutate_historical_fixture do
        references = TranslationReference.where.not(id: original_reference_ids)
        TranslationReferenceRevision.where(translation_reference_id: references.select(:id)).delete_all
        references.delete_all
      end
    end
    UploadBudget.where(user:).delete_all if user
  end
end
