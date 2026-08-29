class TranslationWorkspaceSubmissionCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    TranslationWorkspaceSubmissions::Cleanup.call
  end
end
