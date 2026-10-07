require "digest"

module SourceImports
  # One database-session lock for the whole upload action, including storage
  # callbacks after commit. Row locks alone cannot order these separate commits.
  class RequestLock
    class Unavailable < Error
      def initialize
        super("import_in_progress", "This upload is still being processed. Try again in a moment.")
      end
    end

    def self.key(user_id:, request_key:)
      Digest::SHA256.digest("source_import_request:#{user_id}:#{request_key}").unpack1("q>")
    end

    def self.with(user_id:, request_key:, wait: true)
      # Pre-identity imports cannot have a live creator: new uploads require a
      # key. Their existing row-lock deletion/consumption ordering is sufficient.
      return yield if request_key.nil?

      SourceImport.connection_pool.with_connection do |connection|
        lock_key = key(user_id:, request_key:)
        locked = false
        begin
          if !wait
            locked = connection.select_value(SourceImport.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ]))
            raise Unavailable unless locked
          else
            SourceImport.transaction(requires_new: true) do
            connection.execute("SET LOCAL lock_timeout = '#{Limits::REQUEST_LOCK_WAIT_SECONDS}s'")
            connection.execute(SourceImport.sanitize_sql_array([ "SELECT pg_advisory_lock(?)", lock_key ]))
            end
            locked = true
          end
          yield
        rescue ActiveRecord::LockWaitTimeout
          raise if locked

          raise Unavailable
        ensure
          connection.select_value(SourceImport.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])) if locked
        end
      end
    end
  end
end
