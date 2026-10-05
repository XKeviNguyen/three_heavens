require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/process_barrier"
require_relative "../support/upload_budget_clock"

class TranslationReferenceCreationConcurrencyTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper
  include ProcessBarrier
  include UploadBudgetClock
  self.use_transactional_tests = false

  test "twelve file-backed deliveries replay one redirect one reference one revision and one admission" do
    user = users(:normal)
    original_ids = user.translation_references.pluck(:id)
    UploadBudget.where(user:).delete_all
    9.times { UploadBudget.consume(user:) }
    sign_in_as user
    authenticated_cookies = cookies.to_hash
    key = SecureRandom.hex(16)
    results = in_processes(12) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      authenticated_cookies.each { |name, value| client.cookies[name] = value }
      client.post translation_references_path, params: { translation_reference: {
        creation_key: key, title: "One concurrent reference", source_language: "English", target_language: "Japanese",
        source_file: uploaded_file("Shared file", filename: "shared.txt"), approved_translation: "Approved"
      } }
      [ client.response.status, client.response.location ]
    end
    assert_equal 1, results.uniq.size
    reference = user.translation_references.where.not(id: original_ids).sole
    assert_equal [ 302, translation_reference_url(reference) ], results.first
    assert_equal 1, reference.revisions.count
    budget = UploadBudget.find_by!(user:)
    assert_equal 10, budget.count
    assert_equal 10, budget.receipts.uniq.size
  ensure
    sign_out if signed_in_user_id
    if original_ids
      TranslationReferenceCreation.where(user:).delete_all
      mutate_historical_fixture do
        references = user.translation_references.where.not(id: original_ids)
        TranslationReferenceRevision.where(translation_reference_id: references.select(:id)).delete_all
        references.delete_all
      end
    end
    UploadBudget.where(user:).delete_all if user
  end
end
