require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/translation_reference_test_helper"
require_relative "../support/upload_budget_clock"

class TranslationReferenceCreationTest < ActionDispatch::IntegrationTest
  include DocumentIoTestHelper
  include TranslationReferenceTestHelper
  include UploadBudgetClock

  setup { sign_in_as users(:normal) }

  test "the form supplies a bounded random action key and strict parsing rejects malformed keys" do
    get new_translation_reference_path
    assert_select "input[name='translation_reference[creation_key]']" do |fields|
      assert_match SourceImports::Limits::REQUEST_KEY_FORMAT, fields.sole["value"]
    end
    [ nil, [], {}, "a" * 33, "g" * 32 ].each do |key|
      assert_no_difference([ "TranslationReference.count", "UploadBudget.count" ]) { deliver(key) }
      assert_response :bad_request
    end
  end

  test "lost redirect and double submit replay the initial action even after a later revision" do
    key = ReplayIdentity.issue
    deliver(key)
    reference = TranslationReference.order(:id).last
    assert_redirected_to translation_reference_path(reference)
    assert_equal 1, reference.revisions.count
    assert_nil UploadBudget.find_by(user: users(:normal))
    TranslationReferences::Revise.call(translation_reference: reference, expected_version: "1", attributes: translation_reference_attributes(title: "Revised title"))
    2.times do
      assert_no_difference([ "TranslationReference.count", "TranslationReferenceRevision.count" ]) { deliver(key) }
      assert_redirected_to translation_reference_path(reference)
    end
    assert_equal 2, reference.reload.current_revision.version
  end

  test "same content distinct actions and cross-user key reuse stay independent" do
    key = ReplayIdentity.issue
    deliver(key)
    mine = TranslationReference.order(:id).last
    deliver(ReplayIdentity.issue)
    second = TranslationReference.order(:id).last
    assert_not_equal mine.id, second.id
    sign_out
    sign_in_as users(:other)
    deliver(key)
    theirs = TranslationReference.order(:id).last
    assert_not_equal mine.id, theirs.id
    assert_equal users(:other).id, theirs.user_id
    assert_redirected_to translation_reference_path(theirs)
  end

  test "key reuse with changed content fails and file replay at the cap spends nothing" do
    user = users(:normal)
    9.times { UploadBudget.consume(user:) }
    key = ReplayIdentity.issue
    attributes = -> { translation_reference_attributes(source_text: "").merge(source_file: uploaded_file("Uploaded source", filename: "source.txt")) }
    deliver(key, attributes: attributes.call)
    reference = TranslationReference.order(:id).last
    assert_redirected_to translation_reference_path(reference)
    assert_equal 10, UploadBudget.find_by!(user:).count
    assert_no_difference([ "TranslationReference.count", "TranslationReferenceRevision.count" ]) { deliver(key, attributes: attributes.call) }
    assert_redirected_to translation_reference_path(reference)
    deliver(key, attributes: attributes.call.merge(title: "Changed logical action"))
    assert_response :unprocessable_content
    assert_includes response.body, "different content"
    assert_equal 10, UploadBudget.find_by!(user:).count
    deliver(ReplayIdentity.issue, attributes: attributes.call)
    assert_response :too_many_requests
    assert_equal 10, UploadBudget.find_by!(user:).count
  end

  private

  def deliver(key, attributes: translation_reference_attributes)
    post translation_references_path, params: { translation_reference: attributes.merge(creation_key: key) }
  end
end
