require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class CleanupTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include DocumentIoTestHelper

    class RejectingPurgeQueueAdapter
      attr_reader :attempts

      def initialize
        @attempts = 0
      end

      def enqueue(*)
        @attempts += 1
        raise "purge queue unavailable"
      end

      alias_method :enqueue_at, :enqueue
    end

    test "purges only expired abandoned imports in bounded idempotent batches" do
      fresh = create_ready_import(user: users(:normal), filename: "fresh.txt")
      expired_one = create_ready_import(user: users(:normal), filename: "old-one.txt")
      expired_two = create_ready_import(user: users(:normal), filename: "old-two.txt")
      expired_one.update!(expires_at: 2.days.ago)
      expired_two.update!(expires_at: 2.days.ago)

      result = Cleanup.call(batch_size: 1)
      assert_equal 1, result.purged_count
      assert SourceImport.exists?(fresh.id)
      assert_equal 1, SourceImport.where(id: [ expired_one.id, expired_two.id ]).count

      assert_equal 1, Cleanup.call(batch_size: 100).purged_count
      assert_equal 0, Cleanup.call(batch_size: 100).purged_count
      assert SourceImport.exists?(fresh.id)
    end

    test "synchronously purges an expired upload when the purge queue is unavailable" do
      expired = create_ready_import(user: users(:normal))
      blob = expired.source_file.blob
      attachment_id = expired.source_file.attachment.id
      expired.update!(expires_at: 2.days.ago)
      adapter = RejectingPurgeQueueAdapter.new
      original_adapter = ActiveStorage::PurgeJob.queue_adapter
      ActiveStorage::PurgeJob.queue_adapter = adapter

      assert_no_enqueued_jobs only: [ TranslationRunJob, ReviewRunJob, JudgeRunJob, FinalizationRunJob ] do
        assert_equal 1, Cleanup.call.purged_count
      end

      assert_equal 0, adapter.attempts
      assert_not SourceImport.exists?(expired.id)
      assert_not ActiveStorage::Attachment.exists?(attachment_id)
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not blob.service.exist?(blob.key)
    ensure
      ActiveStorage::PurgeJob.queue_adapter = original_adapter if original_adapter
    end

    test "synchronously purges a failed expired import and its local file" do
      error = assert_raises(Error) do
        Create.call(
          user: users(:normal),
          request_key: ReplayIdentity.issue,
          upload: uploaded_file(
            build_docx(document_xml: "not valid XML"),
            filename: "failed.docx",
            content_type: Detector::DOCX_MIME
          )
        )
      end
      failed = error.source_import
      blob = failed.source_file.blob
      failed.update!(expires_at: 2.days.ago)

      assert_equal 1, Cleanup.call.purged_count
      assert_not SourceImport.exists?(failed.id)
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not blob.service.exist?(blob.key)
    end

    test "retains consumed document attachment even after staging expiration" do
      source_import = create_ready_import(user: users(:normal))
      project = projects(:one)
      document = project.documents.build(title: "Consumed", source_text: "Reviewed")

      SourceImport.transaction do
        locked = SourceImport.lock.find(source_import.id)
        Consume.apply!(source_import: locked, document:)
        document.save!
        Consume.finish!(source_import: locked, document:)
      end
      source_import.update_columns(expires_at: 2.days.ago)

      assert_equal 0, Cleanup.call.purged_count
      assert source_import.reload.consumed?
      assert document.reload.source_file.attached?
      assert_equal "Imported source", document.source_file.download
    end

    test "synchronous SourceImport purge preserves a blob still attached to a Document" do
      source_import = create_ready_import(user: users(:normal))
      project = projects(:one)
      document = project.documents.build(title: "Shared", source_text: "Reviewed")

      SourceImport.transaction do
        locked = SourceImport.lock.find(source_import.id)
        Consume.apply!(source_import: locked, document:)
        document.save!
        Consume.finish!(source_import: locked, document:)
      end
      blob = document.source_file.blob

      assert_no_enqueued_jobs only: ActiveStorage::PurgeJob do
        source_import.destroy!
      end

      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
      assert document.reload.source_file.attached?
      assert_equal "Imported source", document.source_file.download
    end

    test "cleanup job is idempotent and never enqueues provider jobs" do
      expired = create_ready_import(user: users(:normal))
      expired.update!(expires_at: 2.days.ago)

      assert_no_enqueued_jobs only: [ TranslationRunJob, ReviewRunJob, JudgeRunJob, FinalizationRunJob ] do
        SourceImportCleanupJob.perform_now
        SourceImportCleanupJob.perform_now
      end
      assert_not SourceImport.exists?(expired.id)
    end

    test "cleanup rechecks state and cannot delete an import consumed after candidate selection" do
      source_import = create_ready_import(user: users(:normal))
      source_import.update!(expires_at: 2.days.ago)
      cleanup = Cleanup.new(cutoff: Time.current, batch_size: 1)
      project = projects(:one)

      cleanup.define_singleton_method(:candidate_rows) do
        source_import.update!(expires_at: 1.hour.from_now)
        document = project.documents.build(title: "Won race", source_text: "Reviewed")
        SourceImport.transaction do
          locked = SourceImport.lock.find(source_import.id)
          Consume.apply!(source_import: locked, document:)
          document.save!
          Consume.finish!(source_import: locked, document:)
        end
        [ [ source_import.id, source_import.expires_at ] ]
      end
      assert_equal 0, cleanup.call.purged_count

      assert source_import.reload.consumed?
      assert source_import.resulting_document.source_file.attached?
    end
  end
end
