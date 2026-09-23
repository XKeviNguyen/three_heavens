class TranslationWorkspaceDraftCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    TranslationWorkspaceDraft.where(expires_at: ..Time.current).in_batches(of: 100) { |batch| batch.delete_all }
  end
end
