require "test_helper"
require_relative "../support/translation_reference_test_helper"

class TranslationReferenceCreationIntegrityTest < ActiveSupport::TestCase
  include TranslationReferenceTestHelper

  test "failed recovery retains only bounded valid fields and encrypts them" do
    key = SecureRandom.hex(16)
    attributes = translation_reference_attributes(source_text: "x" * 100_001)
    2.times do
      assert_raises(TranslationReferences::AuthoringAttributes::Error) do
        TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
      end
    end
    action = TranslationReferenceCreation.find_by!(user: users(:normal), creation_key: key)
    recovery = JSON.parse(action.failure).fetch("resolved_attributes")
    assert_not recovery.key?("source_text")
    assert_equal attributes.fetch(:approved_translation), recovery.fetch("approved_translation")
    assert_not_includes action.failure_before_type_cast, attributes.fetch(:approved_translation)
    assert_operator action.failure_before_type_cast.bytesize, :<=, TranslationReferenceCreation::MAX_FAILURE_BYTES
    assert_nil UploadBudget.find_by(user: users(:normal))
  end

  test "failure expiry removes recovery data but preserves replay identity" do
    key = SecureRandom.hex(16)
    attributes = translation_reference_attributes(title: "")
    assert_raises(TranslationReferences::AuthoringAttributes::Error) do
      TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
    end
    action = TranslationReferenceCreation.find_by!(user: users(:normal), creation_key: key)
    action.update!(created_at: 25.hours.ago)
    assert_equal 1, TranslationReferenceCreation.expire_failures
    assert action.reload.expired?
    assert_nil action.failure_before_type_cast
    assert_raises(TranslationReferences::Create::Interrupted) do
      TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
    end
    assert_equal 1, TranslationReferenceCreation.where(user: users(:normal), creation_key: key).count
  end

  test "an interrupted or failed action retains its owner through normal model deletion" do
    owner = User.create!(email: "reference-action-owner@example.test", password: "a sufficiently secure password")
    TranslationReferenceCreation.create!(user: owner, creation_key: SecureRandom.hex(16), payload_digest: "a" * 64)

    assert_not owner.destroy
    assert User.exists?(owner.id)
    assert owner.errors[:base].any?
  end

  test "database rejects duplicate keys inconsistent outcomes oversized failure and cross-owner references" do
    reference = create_translation_reference
    action = TranslationReferenceCreation.find_by!(translation_reference: reference)
    assert_db_rejection do
      TranslationReferenceCreation.create!(user: users(:normal), creation_key: action.creation_key, payload_digest: action.payload_digest)
    end
    assert_db_rejection { action.update_columns(translation_reference_id: nil) }
    # An unlinked reference ensures ownership rejection is not masked by
    # the independent one-action-per-reference unique index.
    unlinked = create_translation_reference
    TranslationReferenceCreation.where(translation_reference: unlinked).delete_all
    ownership_error = assert_db_rejection do
      TranslationReferenceCreation.create!(user: users(:other), creation_key: SecureRandom.hex(16), payload_digest: "a" * 64, status: :completed, translation_reference: unlinked)
    end
    assert_instance_of PG::ForeignKeyViolation, ownership_error.cause
    assert_db_rejection do
      action.update_columns(status: "failed", translation_reference_id: nil, failure: SecureRandom.hex(TranslationReferenceCreation::MAX_FAILURE_BYTES))
    end
    assert_db_rejection do
      TranslationReferenceCreation.create!(user: users(:normal), creation_key: "g" * 32, payload_digest: "a" * 64)
    end
  end

  private

  def assert_db_rejection
    assert_raises(ActiveRecord::StatementInvalid) do
      TranslationReferenceCreation.transaction(requires_new: true) { yield }
    end
  end
end
