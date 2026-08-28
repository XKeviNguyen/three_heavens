class SourceImportCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    SourceImports::Cleanup.call
  end
end
