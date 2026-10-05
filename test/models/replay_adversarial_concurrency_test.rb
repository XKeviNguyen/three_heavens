require "test_helper"
require_relative "../support/process_barrier"
require "stringio"

class ReplayAdversarialConcurrencyTest < ActiveSupport::TestCase
  include ProcessBarrier
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup do
    @user = User.create!(email: "adversarial-#{SecureRandom.hex(8)}@example.test", password: "synthetic test password")
  end

  teardown do
    @user.translation_workspace_draft_editors.delete_all
    @user.translation_workspace_drafts.delete_all
    @user.translation_reference_creations.delete_all
    @user.source_import_retirements.delete_all
    @user.source_imports.delete_all
    @user.translation_workspace_submissions.delete_all
    @user.delete
    @blobs&.each { |blob| ActiveStorageMaintenance::Purge.call(blob:) }
  end

  test "independent editor admissions cannot exceed the last available owner slot" do
    (ReplayIdentity::MAX_IDENTITIES_PER_USER - 1).times do
      @user.translation_workspace_draft_editors.create!(context_key: "new", editor_id: identity)
    end
    keys = Array.new(4) { identity }
    results = in_processes(4) do |index|
      begin
        save(keys[index], 1)
        :admitted
      rescue ReplayIdentity::AdmissionExceeded
        :limited
      end
    end
    assert_equal 1, results.count(:admitted)
    assert_equal 3, results.count(:limited)
    assert_equal ReplayIdentity::MAX_IDENTITIES_PER_USER, @user.translation_workspace_draft_editors.count
    assert_equal 1, @user.translation_workspace_drafts.count
  end

  test "independent first-save loser remains rejected after the winner is discarded" do
    winner, loser = identity, identity
    committed_read, committed_write = IO.pipe
    results = in_processes(2) do |index|
      if index.zero?
        result = save(winner, 1)
        committed_write.write("c")
        result.conflict?
      else
        raise "winner missed commit barrier" unless committed_read.read(1) == "c"
        save(loser, 1).conflict?
      end
    end
    assert_equal [ false, true ], results
    TranslationWorkspaceDrafts::Discard.call(user: @user, context_key: "new", draft_id: nil,
      version: nil, editor_id: winner, sequence: 1)
    assert_equal [ true, true ], in_processes(2) { |index| save(loser, index.zero? ? 1 : 100).conflict? }
    assert_empty @user.translation_workspace_drafts
  ensure
    committed_read&.close
    committed_write&.close
  end

  test "a completely advisory-locked source batch cannot starve a healthy tail or spin" do
    imports = Array.new(103) do
      @user.source_imports.create!(status: :failed, original_filename: "synthetic.txt",
        request_key: ReplayIdentity.issue(at: 2.days.ago), expires_at: 1.day.ago)
    end
    locks = imports.first(100).map { |record| "SELECT pg_advisory_lock(#{SourceImports::RequestLock.key(user_id: @user.id, request_key: record.request_key)})" }
    with_process_lock(locks.join(";")) do
      assert_equal 0, SourceImportCleanupJob.perform_now.purged_count
      perform_enqueued_jobs(only: SourceImportCleanupJob) { perform_enqueued_jobs(only: SourceImportCleanupJob) }
      assert_equal imports.first(100).map(&:id), @user.source_imports.order(:id).pluck(:id)
      assert_enqueued_jobs 0, only: SourceImportCleanupJob
      assert_performed_jobs 1, only: SourceImportCleanupJob
    end
    perform_enqueued_jobs(only: SourceImportCleanupJob) { SourceImportCleanupJob.perform_now }
    assert_empty @user.source_imports.reload
  end

  test "a completely advisory-locked reference batch cannot starve healthy identities" do
    records = Array.new(103) do
      @user.translation_reference_creations.create!(creation_key: ReplayIdentity.issue(at: 2.days.ago),
        payload_digest: "a" * 64, expires_at: 1.day.ago)
    end
    locks = records.first(100).map { |record| "SELECT pg_advisory_lock(#{TranslationReferenceCreation.lock_key(user_id: @user.id, creation_key: record.creation_key)})" }
    with_process_lock(locks.join(";")) do
      assert_equal 0, TranslationReferenceCreationCleanupJob.perform_now.fetch(:purged)
      perform_enqueued_jobs(only: TranslationReferenceCreationCleanupJob) { perform_enqueued_jobs(only: TranslationReferenceCreationCleanupJob) }
      assert_equal records.first(100).map(&:id), @user.translation_reference_creations.order(:id).pluck(:id)
      assert_enqueued_jobs 0, only: TranslationReferenceCreationCleanupJob
    end
    perform_enqueued_jobs(only: TranslationReferenceCreationCleanupJob) { TranslationReferenceCreationCleanupJob.perform_now }
    assert_empty @user.translation_reference_creations.reload
  end

  test "two independent blob cleanup workers claim disjoint batches without double purge" do
    @blobs = Array.new(9) do
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic"), filename: "parallel.txt", identify: false)
        .tap { |blob| blob.update_column(:created_at, 8.days.ago) }
    end
    results = in_processes(2) { ActiveStorageMaintenance::Cleanup.call(execute: true, batch_size: 4).purged_count }
    assert_equal [ 4, 4 ], results.sort
    assert_equal 1, ActiveStorage::Blob.where(id: @blobs.map(&:id)).count
    assert_equal 1, ActiveStorageMaintenance::Cleanup.call(execute: true).purged_count
  end

  test "blob cleanup skips an independently held row lock and reaches healthy work" do
    @blobs = Array.new(2) do
      ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic"), filename: "locked.txt", identify: false)
        .tap { |blob| blob.update_column(:created_at, 8.days.ago) }
    end
    with_process_lock("SELECT id FROM active_storage_blobs WHERE id = #{@blobs.first.id} FOR UPDATE") do
      assert_equal 1, ActiveStorageMaintenance::Cleanup.call(execute: true, batch_size: 1).purged_count
      assert ActiveStorage::Blob.exists?(@blobs.first.id)
      assert_not ActiveStorage::Blob.exists?(@blobs.last.id)
    end
    assert_equal 1, ActiveStorageMaintenance::Cleanup.call(execute: true).purged_count
  end

  private

  def identity
    ReplayIdentity.issue(user: @user, context_key: "new")
  end

  def save(editor, sequence)
    TranslationWorkspaceDrafts::Save.call(user: @user, context_key: "new", editor_id: editor, sequence:,
      draft_id: nil, version: nil, payload: { "source_text" => "Synthetic edit" })
  end
end
