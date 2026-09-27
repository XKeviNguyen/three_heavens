require "test_helper"
require_relative "../../support/workflow_profile_test_helper"

module TranslationWorkspaceSubmissions
  class ConcurrencyTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include WorkflowProfileTestHelper

    self.use_transactional_tests = false

    setup do
      suffix = SecureRandom.hex(8)
      @user = User.create!(
        email: "workspace-race-#{suffix}@example.test",
        password: "workspace race password",
        role: :user,
        status: :active,
        email_verified_at: Time.current,
        managed_ai_access: true
      )
      @models = 2.times.map do |index|
        LlmModel.create!(
          gateway: "openrouter",
          provider: "workspace-race-#{suffix}-#{index}",
          model_identifier: "workspace-race/#{suffix}-#{index}",
          display_name: "Workspace race #{index}",
          active: true
        )
      end
      @profile = WorkflowProfiles::Create.call(
        user: @user,
        attributes: {
          name: "Concurrent automatic profile",
          description: "Corrective race coverage",
          completion_mode: "winner_draft",
          translator_ids: @models.map(&:id),
          reviewer_ids: [ @models.first.id ],
          judge_ids: [ @models.last.id ],
          finalizer_ids: []
        }
      )
      clear_enqueued_jobs
    end

    teardown do
      cleanup_test_graph
      clear_enqueued_jobs
    end

    test "two simultaneous automatic submissions with one token launch and schedule exactly once" do
      submission = TranslationWorkspaceSubmission.issue!(user: @user)
      baseline = graph_counts
      results = concurrently(2) do
        TranslationWorkspace.new(workspace_attributes(submission.public_token)).tap(&:submit)
      end

      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      assert results.all? { |workspace| workspace.experiment.persisted? }
      assert_equal 1, results.count(&:replayed?)
      assert_equal [ 1, 1, 1, 1, 2 ], graph_counts.zip(baseline).map { |after, before| after - before }
      assert_equal 2, enqueued_jobs.count { |job| job[:job] == TranslationRunJob }
      assert_equal 1, results.map { |workspace| workspace.experiment.id }.uniq.size
      assert_equal 1, TranslationWorkspaceSubmission.consumed.where(user: @user).count
    end

    test "two concurrent reconcilers remain duplicate safe" do
      workspace = TranslationWorkspace.new(
        workspace_attributes(TranslationWorkspaceSubmission.issue!(user: @user).public_token)
      )
      assert workspace.submit
      clear_enqueued_jobs
      experiment = workspace.experiment
      experiment.translation_runs.order(:id).each_with_index do |run, index|
        run.update!(status: :completed, translated_text: "Translation #{index}", completed_at: Time.current)
      end
      experiment.update!(status: :completed)

      results = concurrently(2) { Pipelines::Reconcile.call(batch_size: 1) }

      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      assert_equal 1, ReviewRound.where(experiment: experiment).count
      assert_equal 1, experiment.reload.review_round.review_runs.count
      assert_equal 1, enqueued_jobs.count { |job| job[:job] == ReviewRunJob }
      assert workspace.pipeline_run.reload.last_reconciled_at
    end

    private

    def workspace_attributes(token)
      {
        user: @user,
        project_name: "Concurrent workspace",
        source_language: "Vietnamese",
        target_language: "Japanese",
        document_title: "One source",
        source_text: "Source",
        experiment_name: "One experiment",
        instruction_prompt: "Translate faithfully.",
        workflow_mode: "automatic",
        workflow_profile_revision_id: @profile.current_revision_id,
        automatic_confirmation: "1",
        model_ids: [],
        submission_token: token
      }
    end

    def graph_counts
      ActiveRecord::Base.uncached do
        [
          Project.where(user: @user).count,
          Document.joins(:project).where(projects: { user_id: @user.id }).count,
          Experiment.joins(document: :project).where(projects: { user_id: @user.id }).count,
          PipelineRun.joins(experiment: { document: :project }).where(projects: { user_id: @user.id }).count,
          TranslationRun.joins(experiment: { document: :project }).where(projects: { user_id: @user.id }).count
        ]
      end
    end

    def concurrently(count, &block)
      ready = Queue.new
      gate = Queue.new
      results = Queue.new
      threads = count.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            gate.pop
            results << block.call
          rescue StandardError => error
            results << error
          end
        end
      end
      count.times { ready.pop }
      count.times { gate << true }
      threads.each(&:join)
      count.times.map { results.pop }
    end

    def cleanup_test_graph
      ActiveRecord::Base.connection.disable_referential_integrity do
        project_ids = Project.where(user_id: @user.id).pluck(:id)
        document_ids = Document.where(project_id: project_ids).pluck(:id)
        experiment_ids = Experiment.where(document_id: document_ids).pluck(:id)
        review_round_ids = ReviewRound.where(experiment_id: experiment_ids).pluck(:id)
        review_run_ids = ReviewRun.where(review_round_id: review_round_ids).pluck(:id)

        ReviewEvaluation.where(review_run_id: review_run_ids).delete_all
        ReviewRun.where(id: review_run_ids).delete_all
        ReviewRound.where(id: review_round_ids).delete_all
        PipelineEvent.where(pipeline_run_id: PipelineRun.where(experiment_id: experiment_ids).select(:id)).delete_all
        PipelineRun.where(experiment_id: experiment_ids).delete_all
        TranslationRun.where(experiment_id: experiment_ids).delete_all
        TranslationWorkspaceSubmission.where(user_id: @user.id).delete_all
        Experiment.where(id: experiment_ids).delete_all
        Document.where(id: document_ids).delete_all
        Project.where(id: project_ids).delete_all

        profile_ids = WorkflowProfile.where(user_id: @user.id).pluck(:id)
        revision_ids = WorkflowProfileRevision.where(workflow_profile_id: profile_ids).pluck(:id)
        WorkflowProfile.where(id: profile_ids).update_all(current_revision_id: nil)
        WorkflowProfileModelSelection.where(workflow_profile_revision_id: revision_ids).delete_all
        WorkflowProfileRevision.where(id: revision_ids).delete_all
        WorkflowProfile.where(id: profile_ids).delete_all
        @models.each(&:delete)
        @user.delete
      end
    end
  end
end
