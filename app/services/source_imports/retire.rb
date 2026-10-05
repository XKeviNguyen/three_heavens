module SourceImports
  # User cancellation and expiry both terminally retire the action before its
  # staged content is destroyed. A delayed delivery then cannot start new work.
  class Retire
    def self.call(source_import:, cutoff: nil)
      RequestLock.with(user_id: source_import.user_id, request_key: source_import.request_key) do
        SourceImport.transaction(requires_new: true) do
          # The initially authorized row may have disappeared (Busy or another
          # cancellation), or been consumed while this request waited.
          current = SourceImport.where(user_id: source_import.user_id).lock.find(source_import.id)
          next false unless current.status.in?(%w[pending ready failed])
          next false if cutoff && current.expires_at > cutoff

          if current.request_key
            SourceImportRetirement.create!(user_id: current.user_id, request_key: current.request_key,
              expires_at: ReplayIdentity.expires_at(current.request_key) || ReplayIdentity::LIFETIME.from_now)
          end
          current.destroy!
          true
        end
      end
    end
  end
end
