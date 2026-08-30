class TranslationWorkspaceSubmissionCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    result = TranslationWorkspaceSubmissions::Cleanup.call
    Operations::EventLogger.emit(
      "workspace_submission_cleanup_completed",
      active_job_id: job_id,
      outcome: "success",
      count: result.purged_count
    )
    result
  end
end
