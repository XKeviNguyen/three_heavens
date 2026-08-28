require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class ConsumptionConcurrencyTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include DocumentIoTestHelper

    self.use_transactional_tests = false

    class NoopStart
      def self.call(**)
        []
      end
    end

    setup do
      suffix = SecureRandom.hex(8)
      @user = User.create!(
        email: "concurrency-#{suffix}@example.test",
        password: "concurrency secure password",
        role: :user,
        status: :active
      )
      @model = LlmModel.create!(
        gateway: "openrouter",
        provider: "concurrency-provider-#{suffix}",
        model_identifier: "concurrency/#{suffix}",
        display_name: "Concurrency #{suffix}",
        active: true
      )
      @source_import = create_ready_import(user: @user)
    end

    teardown do
      project_ids = Project.where(user_id: @user.id).pluck(:id)
      document_ids = Document.where(project_id: project_ids).pluck(:id)
      SourceImport.where(user_id: @user.id).destroy_all
      Experiment.where(document_id: document_ids).delete_all
      ActiveStorage::Attachment.where(record_type: "Document", record_id: document_ids).delete_all
      Document.where(id: document_ids).delete_all
      Project.where(id: project_ids).delete_all
      @user.delete if @user&.persisted?
      @model.delete if @model&.persisted?
      ActiveStorage::Blob.where.missing(:attachments).delete_all
      clear_enqueued_jobs
    end

    test "two concurrent submissions can consume an import only once" do
      gate = Queue.new
      results = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            source_import = SourceImport.find(@source_import.id)
            workspace = TranslationWorkspace.new(
              workspace_attributes(source_import),
              start_service: NoopStart
            )
            gate.pop
            results << workspace.submit
          end
        rescue StandardError => error
          results << error
        end
      end
      2.times { gate << true }
      threads.each(&:join)

      outcomes = 2.times.map { results.pop }
      errors = outcomes.grep(Exception)
      assert_empty errors, errors.map(&:full_message).join("\n")
      assert_equal [ false, true ], outcomes.sort_by { |value| value ? 1 : 0 }
      assert @source_import.reload.consumed?
      assert_equal 1, Project.where(user_id: @user.id).count
      assert_equal 1, @source_import.resulting_document.experiments.count
    end

    private

    def workspace_attributes(source_import)
      {
        user: @user,
        source_import:,
        source_import_id: source_import.id,
        project_name: "Concurrent import",
        source_language: "Vietnamese",
        target_language: "Japanese",
        document_title: "Concurrent source",
        source_text: "Reviewed source",
        experiment_name: "One-time consume",
        instruction_prompt: "Translate faithfully.",
        model_ids: [ @model.id ]
      }
    end
  end
end
