class SessionCleanupJob < ApplicationJob
  queue_as :operations

  def perform
    Session.expired.in_batches(of: 1_000) { |batch| batch.delete_all }
    ConsumedNonce.expired.in_batches(of: 1_000) { |batch| batch.delete_all }
  end
end
