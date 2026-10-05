require "test_helper"
require_relative "../support/document_io_test_helper"
require_relative "../support/translation_reference_test_helper"

class ReplayLifecycleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include DocumentIoTestHelper
  include TranslationReferenceTestHelper

  test "signed action deadline cannot be extended by changing its suffix or signature" do
    freeze_time
    key = ReplayIdentity.issue
    assert ReplayIdentity.valid?(key)
    assert_nil ReplayIdentity.expires_at("#{key.split('--').first}--#{'a' * 64}.#{'b' * 32}")
    travel ReplayIdentity::LIFETIME do
      assert_not ReplayIdentity.valid?(key)
      assert_not ReplayIdentity.valid?("#{key.split('.').first}.#{SecureRandom.hex(16)}")
    end
  end

  test "retirement survives its valid replay window and expires exactly at the boundary" do
    freeze_time
    key = ReplayIdentity.issue
    source_import = SourceImports::Create.call(user: users(:normal), upload: uploaded_file("Retired", filename: "retired.txt"), request_key: key)
    assert SourceImports::Retire.call(source_import:)
    tombstone = SourceImportRetirement.find_by!(request_key: key)
    travel_to(tombstone.expires_at - 1.second) do
      assert_equal 0, SourceImports::Cleanup.call.retirements_purged_count
      error = assert_raises(SourceImports::Error) do
        SourceImports::Create.call(user: users(:normal), upload: uploaded_file("Retired", filename: "retired.txt"), request_key: key)
      end
      assert_equal "import_unavailable", error.code
    end
    travel_to(tombstone.expires_at) do
      assert_equal 1, SourceImports::Cleanup.call.retirements_purged_count
      assert_equal 0, SourceImports::Cleanup.call.retirements_purged_count
      assert_no_difference [ "SourceImport.count", "UploadBudget.sum(:count)" ] do
        assert_raises(SourceImports::Error) do
          SourceImports::Create.call(user: users(:normal), upload: uploaded_file("Retired", filename: "retired.txt"), request_key: key)
        end
      end
    end
  end

  test "discard keeps a protective watermark and expired editors cannot overwrite a newer tab" do
    freeze_time
    editor_a, editor_b = ReplayIdentity.issue, ReplayIdentity.issue
    saved = save(editor_a, 1, "A")
    TranslationWorkspaceDrafts::Discard.call(user: users(:normal), context_key: "new", draft_id: nil,
      version: nil, editor_id: editor_a, sequence: 1)
    assert_equal 0, TranslationWorkspaceDraftEditor.purge_expired
    assert save(editor_a, 1, "Delayed A").conflict?
    draft_b = save(editor_b, 1, "B").draft
    assert save(editor_a, 2, "Other tab A").conflict?
    assert_equal "B", draft_b.reload.payload.fetch("source_text")
    assert_not TranslationWorkspaceDraft.exists?(saved.draft.id)

    travel ReplayIdentity::LIFETIME do
      assert_equal 2, TranslationWorkspaceDraftEditor.purge_expired
      assert_equal 0, TranslationWorkspaceDraftEditor.purge_expired
      assert_raises(TranslationWorkspaceDraftEditor::Expired) { save(editor_a, 3, "Ancient A") }
      # Even possessing the newer draft/version cannot renew the old lease.
      assert_raises(TranslationWorkspaceDraftEditor::Expired) do
        save(editor_a, 4, "Ancient A", draft_id: draft_b.public_id, version: draft_b.lock_version)
      end
      assert_equal "B", draft_b.reload.payload.fetch("source_text")
      assert_equal 0, TranslationWorkspaceDraftEditor.count
    end
  end

  test "expired draft deletion retains its still valid editor watermark" do
    freeze_time
    editor = ReplayIdentity.issue
    draft = save(editor, 3, "Expired content").draft
    draft.update!(expires_at: Time.current)
    assert_equal({ drafts: 1, editors: 0 }, TranslationWorkspaceDraftCleanupJob.perform_now)
    assert save(editor, 3, "Delayed content").conflict?
    assert_equal 1, TranslationWorkspaceDraftEditor.count
  end

  test "recovery expiration and final identity purge have distinct clocks" do
    freeze_time
    key = ReplayIdentity.issue
    attributes = translation_reference_attributes(title: "")
    assert_raises(TranslationReferences::AuthoringAttributes::Error) do
      TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
    end
    action = TranslationReferenceCreation.find_by!(creation_key: key)
    action.update!(created_at: 25.hours.ago)
    assert_equal({ expired: 1, purged: 0 }, TranslationReferenceCreationCleanupJob.perform_now)
    assert action.reload.expired?
    assert_nil action.failure_before_type_cast
    assert_raises(TranslationReferences::Create::Interrupted) do
      TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
    end
    travel_to(action.expires_at) do
      assert_equal 1, TranslationReferenceCreationCleanupJob.perform_now.fetch(:purged)
      assert_not TranslationReferenceCreation.exists?(action.id)
      assert_raises(TranslationReferences::Create::Interrupted) do
        TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
      end
    end
  end

  test "completed reference identity is bounded but its canonical reference survives" do
    freeze_time
    key = ReplayIdentity.issue
    attributes = translation_reference_attributes
    reference = TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
    assert_equal 0, TranslationReferenceCreation.purge_expired
    assert_equal reference, TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
    travel ReplayIdentity::LIFETIME do
      assert_equal 1, TranslationReferenceCreation.purge_expired
      assert TranslationReference.exists?(reference.id)
      assert_no_difference "TranslationReference.count" do
        assert_raises(TranslationReferences::Create::Interrupted) do
          TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: key)
        end
      end
    end
  end

  test "all coordination ledgers make bounded progress and converge without touching recent rows" do
    freeze_time
    models = [ SourceImportRetirement, TranslationWorkspaceDraftEditor, TranslationReferenceCreation ]
    models.each do |model|
      keys = Array.new(9) { ReplayIdentity.issue(at: 2.days.ago) }
      keys.each { |key| insert_identity(model, key, expires_at: 1.day.ago) }
      recent = insert_identity(model, ReplayIdentity.issue, expires_at: 1.day.from_now)
      assert_equal [ 4, 4, 1, 0 ], Array.new(4) { model.purge_expired(batch_size: 4) }
      assert_equal [ recent.id ], model.pluck(:id)
      # An excessive requested batch still has the fixed hard limit.
      101.times { insert_identity(model, ReplayIdentity.issue(at: 2.days.ago), expires_at: 1.day.ago) }
      assert_equal 100, model.purge_expired(batch_size: 10_000)
      assert_equal 1, model.purge_expired
      assert model.exists?(recent.id)
    end
  end

  test "legacy identities replay existing state during grace and never create missing state" do
    freeze_time
    key = SecureRandom.hex(16)
    action = TranslationReferenceCreation.create!(user: users(:normal), creation_key: key,
      payload_digest: "a" * 64, expires_at: 1.hour.from_now)
    assert ReplayIdentity.valid?(key, existing: action)
    assert_not ReplayIdentity.valid?(key)
    travel 1.hour do
      assert_equal 1, TranslationReferenceCreation.purge_expired
      assert_not ReplayIdentity.valid?(key, existing: action)
      assert_raises(TranslationReferences::Create::Interrupted) do
        TranslationReferences::Create.call(user: users(:normal), creation_key: key, attributes: translation_reference_attributes)
      end
    end
  end

  test "scheduled cleanup chains drain backlogs while each job keeps its bound" do
    freeze_time
    {
      SourceImportRetirement => SourceImportCleanupJob,
      TranslationWorkspaceDraftEditor => TranslationWorkspaceDraftCleanupJob,
      TranslationReferenceCreation => TranslationReferenceCreationCleanupJob
    }.each do |model, job|
      clear_enqueued_jobs
      clear_performed_jobs
      101.times { insert_identity(model, ReplayIdentity.issue(at: 2.days.ago), expires_at: 1.day.ago) }
      recent = insert_identity(model, ReplayIdentity.issue, expires_at: 1.day.from_now)
      job.perform_now
      assert_equal 2, model.count, "the first invocation must leave a bounded backlog and the recent row"
      assert_enqueued_jobs 1, only: job
      # Enable execution of successors while flushing the initially queued job.
      perform_enqueued_jobs(only: job) { perform_enqueued_jobs(only: job) }
      assert_equal [ recent.id ], model.pluck(:id)
      assert_enqueued_jobs 0, only: job
      assert_performed_jobs model == TranslationReferenceCreation ? 2 : 1, only: job
    end
  end

  private

  def save(editor, sequence, text, draft_id: nil, version: nil)
    TranslationWorkspaceDrafts::Save.call(user: users(:normal), context_key: "new", payload: { "source_text" => text },
      draft_id:, version:, editor_id: editor, sequence:)
  end

  def insert_identity(model, key, expires_at:)
    attributes = case model.name
    when "SourceImportRetirement" then { request_key: key }
    when "TranslationWorkspaceDraftEditor" then { context_key: "new", editor_id: key, sequence: 1 }
    when "TranslationReferenceCreation" then { creation_key: key, payload_digest: "a" * 64 }
    end
    model.create!(user: users(:normal), expires_at:, **attributes)
  end
end
