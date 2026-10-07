require "test_helper"
require "stringio"

class ReplayAdversarialTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  setup { sign_in_as users(:normal) }

  test "one page credential cannot manufacture editor identities through suffix mutation" do
    get new_translation_workspace_path
    page = Nokogiri::HTML(response.body)
    credential = page.at_css("[data-controller='workspace-guard']")["data-workspace-guard-editor-id-value"] ||
      page.at_css("[data-controller='workspace-guard']")["data-workspace-guard-replay-lease-value"]
    1000.times do |index|
      identity = "#{credential.split('.').first}.#{index.to_s(16).rjust(32, '0')}"
      begin
        TranslationWorkspaceDrafts::Discard.call(user: users(:normal), context_key: "new",
          draft_id: nil, version: nil, editor_id: identity, sequence: 0)
      rescue TranslationWorkspaceDraftEditor::Expired, ActiveRecord::RecordInvalid
        # Tampered identities must not write durable state.
      end
    end
    assert_operator users(:normal).translation_workspace_draft_editors.count, :<=, 1
    assert_equal 0, TranslationWorkspaceDraft.count
  end

  test "lost first-save conflict cannot become accepted after the winner disappears" do
    editor_a, editor_b = Array.new(2) { ReplayIdentity.issue(user: users(:normal), context_key: "new") }
    save(editor_b, 1, "Winner")
    assert save(editor_a, 1, "Rejected").conflict?
    TranslationWorkspaceDrafts::Discard.call(user: users(:normal), context_key: "new",
      draft_id: nil, version: nil, editor_id: editor_b, sequence: 1)
    assert save(editor_a, 1, "Lost-response retry").conflict?
    assert_equal 0, TranslationWorkspaceDraft.count
  end

  test "page editors are independent owner and context bound and nonrenewable" do
    freeze_time
    get new_translation_workspace_path
    first = Nokogiri::HTML(response.body).at_css("[data-workspace-guard-editor-id-value]")["data-workspace-guard-editor-id-value"]
    get new_translation_workspace_path
    second = Nokogiri::HTML(response.body).at_css("[data-workspace-guard-editor-id-value]")["data-workspace-guard-editor-id-value"]
    assert_not_equal first, second
    assert ReplayIdentity.complete?(first, user: users(:normal), context_key: "new")
    assert_no_difference "TranslationWorkspaceDraftEditor.count" do
      delete translation_workspace_draft_path, params: { editor_id: first, project_id: projects(:one).id.to_s, sequence: 0 }, as: :json
      assert_response :conflict
      sign_out
      sign_in_as users(:other)
      delete translation_workspace_draft_path, params: { editor_id: first, sequence: 0 }, as: :json
      assert_response :conflict
    end
    sign_out
    sign_in_as users(:normal)
    travel ReplayIdentity::LIFETIME do
      assert_no_difference "TranslationWorkspaceDraftEditor.count" do
        delete translation_workspace_draft_path, params: { editor_id: first, sequence: 0 }, as: :json
        assert_response :conflict
      end
    end
  end

  test "resident editor admission cap is enforced before durable work and allows exact retries" do
    user = users(:normal)
    identities = Array.new(ReplayIdentity::MAX_IDENTITIES_PER_USER) { ReplayIdentity.issue(user:, context_key: "new") }
    identities.each { |editor_id| user.translation_workspace_draft_editors.create!(context_key: "new", editor_id:) }
    assert_no_difference [ "TranslationWorkspaceDraftEditor.count", "TranslationWorkspaceDraft.count", "ActiveStorage::Blob.count" ] do
      delete translation_workspace_draft_path, params: { editor_id: ReplayIdentity.issue(user:, context_key: "new"), sequence: 0 }, as: :json
      assert_response :too_many_requests
      delete translation_workspace_draft_path, params: { editor_id: identities.first, sequence: 0 }, as: :json
      assert_response :no_content
    end
  end

  test "reference creation cannot derive identities from an upload lease and has a resident admission bound" do
    credential = ReplayIdentity.lease
    attributes = { title: "", source_language: "Japanese", target_language: "English" }
    assert_no_difference [ "TranslationReferenceCreation.count", "TranslationReference.count" ] do
      20.times do
        assert_raises(TranslationReferences::Create::Interrupted) do
          TranslationReferences::Create.call(user: users(:normal), attributes:, creation_key: "#{credential}.#{SecureRandom.hex(16)}")
        end
      end
    end
    ReplayIdentity::MAX_IDENTITIES_PER_USER.times do
      users(:normal).translation_reference_creations.create!(creation_key: ReplayIdentity.issue, payload_digest: "a" * 64)
    end
    assert_no_difference [ "TranslationReferenceCreation.count", "UploadBudget.count", "ActiveStorage::Blob.count" ] do
      assert_raises(TranslationReferences::Create::Interrupted) do
        TranslationReferences::Create.call(user: users(:normal), attributes:)
      end
    end
  end

  test "losing and stale discard editors remain rejected after discard launch or content cleanup" do
    %i[discard launch cleanup].each do |removal|
      winner, loser = Array.new(2) { ReplayIdentity.issue(user: users(:normal), context_key: "new") }
      draft = save(winner, 1, "Winner").draft
      assert save(loser, 1, "Rejected").conflict?
      conflict = TranslationWorkspaceDrafts::Discard.call(user: users(:normal), context_key: "new",
        draft_id: nil, version: nil, editor_id: loser, sequence: 2)
      assert conflict
      case removal
      when :discard
        TranslationWorkspaceDrafts::Discard.call(user: users(:normal), context_key: "new",
          draft_id: nil, version: nil, editor_id: winner, sequence: 1)
      when :launch
        TranslationWorkspaceDrafts::Discard.after_launch(user: users(:normal), context_key: "new", public_id: draft.public_id, version: draft.lock_version)
      when :cleanup
        draft.update!(expires_at: Time.current)
        TranslationWorkspaceDraftCleanupJob.perform_now
      end
      [ 1, 2, 100 ].each { |sequence| assert save(loser, sequence, "Delayed loser").conflict? }
      assert TranslationWorkspaceDrafts::Discard.call(user: users(:normal), context_key: "new",
        draft_id: nil, version: nil, editor_id: loser, sequence: 2)
      assert_equal 0, TranslationWorkspaceDraft.count
    end
  end

  test "persistent oldest blob failures cannot starve later healthy candidates" do
    freeze_time
    blobs = Array.new(105) do |index|
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic"), filename: "fairness-#{index}.txt",
        content_type: "text/plain", identify: false).tap { |blob| blob.update_column(:created_at, 8.days.ago + index.seconds) }
    end
    poison_keys = blobs.first(100).map(&:key)
    service = ActiveStorage::Blob.service
    original_delete = service.method(:delete)
    failing_delete = ->(key) { poison_keys.include?(key) ? raise(IOError, "synthetic persistent storage outage") : original_delete.call(key) }
    service.define_singleton_method(:delete, failing_delete)
    3.times { assert_operator ActiveStorageMaintenance::Cleanup.call(execute: true).candidate_count, :<=, 100 }
    assert_equal 100, ActiveStorage::Blob.where(id: blobs.map(&:id)).count
    assert_not ActiveStorage::Blob.exists?(blobs.last.id)
    assert_equal 0, ActiveStorageMaintenance::Cleanup.call(execute: true).candidate_count
    service.define_singleton_method(:delete, original_delete)
    travel ActiveStorageMaintenance::Cleanup::RETRY_DELAY do
      assert_equal 100, ActiveStorageMaintenance::Cleanup.call(execute: true).purged_count
      assert_not ActiveStorage::Blob.where(id: blobs.map(&:id)).exists?
    end
  ensure
    service&.define_singleton_method(:delete, original_delete) if original_delete
    blobs&.each { |blob| ActiveStorageMaintenance::Purge.call(blob:) }
  end

  test "an unavailable legacy service cannot abort healthy cleanup or its successor" do
    freeze_time
    blobs = Array.new(105) do |index|
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic"), filename: "legacy-#{index}.txt", identify: false)
        .tap { |blob| blob.update_column(:created_at, 8.days.ago + index.seconds) }
    end
    original_service = blobs.first.service_name
    blobs.first.update_column(:service_name, "unavailable_legacy_service")
    result = ActiveStorageCleanupJob.perform_now
    assert_equal 100, result.candidate_count
    assert_equal 99, result.purged_count
    assert_enqueued_jobs 1, only: ActiveStorageCleanupJob
    perform_enqueued_jobs(only: ActiveStorageCleanupJob)
    assert_equal [ blobs.first.id ], ActiveStorage::Blob.where(id: blobs.map(&:id)).pluck(:id)
    assert_equal 0, ActiveStorageMaintenance::Cleanup.call(execute: true).candidate_count
    blobs.first.update!(service_name: original_service)
    travel ActiveStorageMaintenance::Cleanup::RETRY_DELAY do
      assert_equal 1, ActiveStorageMaintenance::Cleanup.call(execute: true).purged_count
    end
  ensure
    blobs&.each { |blob| ActiveStorageMaintenance::Purge.call(blob:) }
  end

  private

  def save(editor, sequence, text)
    TranslationWorkspaceDrafts::Save.call(user: users(:normal), context_key: "new", payload: { "source_text" => text },
      draft_id: nil, version: nil, editor_id: editor, sequence:)
  end
end
