class TranslationWorkspaceDraftCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    # Fixed per-invocation bounds, including when a scheduler has fallen behind.
    count = TranslationWorkspaceDraft.transaction do
      ids = TranslationWorkspaceDraft.where(expires_at: ..Time.current).order(:expires_at, :id)
        .limit(100).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      TranslationWorkspaceDraft.where(id: ids).delete_all
    end
    editors = TranslationWorkspaceDraftEditor.purge_expired
    Operations::EventLogger.emit("workspace_draft_cleanup_completed", active_job_id: job_id, outcome: "success", count:)
    Operations::EventLogger.emit("workspace_editor_cleanup_completed", active_job_id: job_id, outcome: "success", count: editors)
    self.class.perform_later if count == 100 || editors == 100
    { drafts: count, editors: }
  end
end
