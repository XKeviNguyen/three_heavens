require "test_helper"
require_relative "../support/document_io_test_helper"

class SourceImportRetirementTest < ActiveSupport::TestCase
  include DocumentIoTestHelper

  test "failed destruction rolls back retirement and leaves the stored import usable" do
    source_import = create_ready_import(user: users(:normal))
    blob = source_import.source_file.blob
    reject = ->(record) { throw :abort if record.id == source_import.id }
    SourceImport.set_callback(:destroy, :before, reject)

    assert_raises(ActiveRecord::RecordNotDestroyed) { SourceImports::Retire.call(source_import:) }
    assert_not SourceImportRetirement.exists?(user: users(:normal), request_key: source_import.request_key)
    assert source_import.reload.available?
    assert blob.service.exist?(blob.key)
  ensure
    SourceImport.skip_callback(:destroy, :before, reject) if reject
  end

  test "legacy imports without request keys remain cancellable" do
    source_import = create_ready_import(user: users(:normal))
    source_import.update!(request_key: nil)
    assert_no_difference "SourceImportRetirement.count" do
      assert SourceImports::Retire.call(source_import:)
    end
    assert_not SourceImport.exists?(source_import.id)
  end

  test "PostgreSQL enforces owned unique bounded retirement identities" do
    key = SecureRandom.hex(16)
    SourceImportRetirement.create!(user: users(:normal), request_key: key)
    reject_in_database { SourceImportRetirement.create!(user: users(:normal), request_key: key) }
    reject_in_database { SourceImportRetirement.insert_all!([ { user_id: users(:normal).id, request_key: "g" * 32, created_at: Time.current } ]) }
    reject_in_database { SourceImportRetirement.insert_all!([ { user_id: users(:normal).id, request_key: "a" * 33, created_at: Time.current } ]) }
    reject_in_database { SourceImportRetirement.insert_all!([ { user_id: -1, request_key: key, created_at: Time.current } ]) }
    assert SourceImportRetirement.create!(user: users(:other), request_key: key).persisted?
  end

  private

  def reject_in_database(&work)
    assert_raises(ActiveRecord::StatementInvalid) do
      SourceImportRetirement.transaction(requires_new: true, &work)
    end
  end
end
