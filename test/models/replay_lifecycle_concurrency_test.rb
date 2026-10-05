require "test_helper"
require_relative "../support/process_barrier"
require_relative "../support/document_io_test_helper"
require_relative "../support/translation_reference_test_helper"

class ReplayLifecycleConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ProcessBarrier
  include DocumentIoTestHelper
  include TranslationReferenceTestHelper
  self.use_transactional_tests = false

  setup do
    @user = User.create!(email: "lifecycle-#{SecureRandom.hex(8)}@example.test", password: "safe synthetic password")
  end

  teardown do
    SourceImportRetirement.where(user: @user).delete_all
    TranslationWorkspaceDraftEditor.where(user: @user).delete_all
    TranslationReferenceCreation.where(user: @user).delete_all
    TranslationWorkspaceDraft.where(user: @user).delete_all
    @user.source_imports.find_each(&:destroy!)
    mutate_historical_fixture do
      TranslationReferenceRevision.where(translation_reference_id: @user.translation_references.select(:id)).delete_all
      TranslationReference.where(user: @user).delete_all
    end
    UploadBudget.where(user: @user).delete_all
    @user.delete
  end

  test "two cleanup processes make bounded progress in every coordination ledger" do
    freeze_time
    [ SourceImportRetirement, TranslationWorkspaceDraftEditor, TranslationReferenceCreation ].each do |model|
      attributes = case model.name
      when "SourceImportRetirement" then { request_key: ReplayIdentity.issue(at: 2.days.ago) }
      when "TranslationWorkspaceDraftEditor" then { context_key: "new", editor_id: ReplayIdentity.issue(at: 2.days.ago) }
      when "TranslationReferenceCreation" then { creation_key: ReplayIdentity.issue(at: 2.days.ago), payload_digest: "a" * 64 }
      end
      key_field = %i[request_key editor_id creation_key].find { |key| attributes.key?(key) }
      9.times do
        model.create!(user: @user, expires_at: 1.day.ago, **attributes.merge(key_field => ReplayIdentity.issue(at: 2.days.ago)))
      end
      results = in_processes(2) { model.purge_expired(batch_size: 4) }
      assert_equal [ 4, 4 ], results.sort
      assert_equal 1, model.where(user: @user).count
      assert_equal 1, model.purge_expired
    end
  end

  test "retirement racing cleanup retains the new tombstone and rejects a valid replay" do
    key = ReplayIdentity.issue
    source_import = SourceImports::Create.call(user: @user, upload: uploaded_file("Cancel", filename: "cancel.txt"), request_key: key)
    in_processes(2) do |worker|
      worker.zero? ? SourceImports::Retire.call(source_import:) : SourceImports::Cleanup.call.retirements_purged_count
    end
    assert SourceImportRetirement.exists?(user: @user, request_key: key)
    assert_not SourceImport.exists?(source_import.id)
    assert_raises(SourceImports::Error) do
      SourceImports::Create.call(user: @user, upload: uploaded_file("Cancel", filename: "cancel.txt"), request_key: key)
    end
  end

  test "cleanup and expired completed replay cannot create another reference" do
    freeze_time
    key = ReplayIdentity.issue
    attributes = translation_reference_attributes
    reference = TranslationReferences::Create.call(user: @user, attributes:, creation_key: key)
    travel_to TranslationReferenceCreation.find_by!(translation_reference: reference).expires_at
    results = in_processes(2) do |worker|
      next TranslationReferenceCreation.purge_expired if worker.zero?
      begin
        TranslationReferences::Create.call(user: @user, attributes:, creation_key: key)
      rescue TranslationReferences::Create::Interrupted
        :expired
      end
    end
    assert_equal :expired, results.last
    assert_includes [ 0, 1 ], results.first
    # Cleanup may deliberately skip the expired request while its replay
    # holds the action lock; the next invocation must finish the purge.
    assert_equal 1, results.first + TranslationReferenceCreation.purge_expired
    assert_equal [ reference.id ], @user.translation_references.pluck(:id)
    assert_equal 0, TranslationReferenceCreation.where(user: @user).count
  end

  test "an expired live reference action survives cleanup until its independent session releases its lock" do
    action = TranslationReferenceCreation.create!(user: @user, creation_key: ReplayIdentity.issue(at: 2.days.ago),
      payload_digest: "a" * 64, expires_at: 1.day.ago)
    with_process_lock("SELECT pg_advisory_lock(#{TranslationReferenceCreation.lock_key(user_id: @user.id, creation_key: action.creation_key)})") do
      assert_equal 0, TranslationReferenceCreation.purge_expired
      assert TranslationReferenceCreation.exists?(action.id)
    end
    assert_equal 1, TranslationReferenceCreation.purge_expired
  end

  test "editor cleanup skips a row being saved or discarded in another process" do
    editor = TranslationWorkspaceDraftEditor.create!(user: @user, context_key: "new",
      editor_id: ReplayIdentity.issue(at: 2.days.ago), sequence: 2, expires_at: 1.day.ago)
    with_process_lock("SELECT id FROM translation_workspace_draft_editors WHERE id = #{editor.id} FOR UPDATE") do
      assert_equal 0, TranslationWorkspaceDraftEditor.purge_expired
      assert TranslationWorkspaceDraftEditor.exists?(editor.id)
    end
    assert_equal 1, TranslationWorkspaceDraftEditor.purge_expired
  end

  test "recovery cleanup skips an independently locked failed action" do
    action = TranslationReferenceCreation.create!(user: @user, creation_key: ReplayIdentity.issue,
      payload_digest: "a" * 64, status: :failed, failure: JSON.generate(message: "Synthetic failure"),
      created_at: 25.hours.ago, expires_at: 1.hour.from_now)
    with_process_lock("SELECT id FROM translation_reference_creations WHERE id = #{action.id} FOR UPDATE") do
      assert_equal 0, TranslationReferenceCreation.expire_failures
      assert action.reload.failed?
    end
    assert_equal 1, TranslationReferenceCreation.expire_failures
    assert action.reload.expired?
    assert_nil action.failure_before_type_cast
  end

  test "source cleanup continuation progresses past a live locked candidate and stops without spinning" do
    imports = Array.new(101) do
      @user.source_imports.create!(status: :failed, original_filename: "synthetic.txt",
        request_key: ReplayIdentity.issue(at: 2.days.ago), expires_at: 1.day.ago)
    end
    oldest = imports.first
    lock_key = SourceImports::RequestLock.key(user_id: @user.id, request_key: oldest.request_key)
    with_process_lock("SELECT pg_advisory_lock(#{lock_key})") do
      assert_equal 99, SourceImportCleanupJob.perform_now.purged_count
      assert_equal 2, @user.source_imports.count
      perform_enqueued_jobs(only: SourceImportCleanupJob) { perform_enqueued_jobs(only: SourceImportCleanupJob) }
      assert_equal [ oldest.id ], @user.source_imports.pluck(:id)
      assert_enqueued_jobs 0, only: SourceImportCleanupJob
      assert_performed_jobs 1, only: SourceImportCleanupJob
    end
    perform_enqueued_jobs(only: SourceImportCleanupJob) { assert_equal 1, SourceImportCleanupJob.perform_now.purged_count }
    assert_empty @user.source_imports.reload
  end
end
