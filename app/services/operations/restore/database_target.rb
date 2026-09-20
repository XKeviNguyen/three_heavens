require "pg"

module Operations
  module Restore
    class DatabaseTarget
      class UnsafeDatabase < StandardError; end

      USER_TABLE_COUNT_SQL = <<~SQL.squish.freeze
        SELECT COUNT(*)
        FROM pg_catalog.pg_tables
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
      SQL
      IDENTITY_SQL = <<~SQL.squish.freeze
        SELECT current_database(), COALESCE(inet_server_addr()::text, 'local'), COALESCE(inet_server_port(), 0)
      SQL

      def initialize(target_url:, live_url: ENV["DATABASE_URL"], connector: PG)
        @target_url = target_url.to_s
        @live_url = live_url.to_s
        @connector = connector
      end

      def validate!
        raise UnsafeDatabase, "RESTORE_DATABASE_URL is required" if target_url.empty?
        raise UnsafeDatabase, "restore database cannot equal the live database" if live_url.present? && target_url == live_url

        target = connector.connect(target_url)
        begin
          if live_url.present? && same_database?(target)
            raise UnsafeDatabase, "restore database resolves to the live database"
          end
          count = Integer(target.exec(USER_TABLE_COUNT_SQL).getvalue(0, 0))
          raise UnsafeDatabase, "restore database must be empty" unless count.zero?
        ensure
          target.close
        end
        true
      rescue PG::Error
        raise UnsafeDatabase, "restore database is unavailable"
      end

      private

      attr_reader :connector, :live_url, :target_url

      def same_database?(target)
        live = connector.connect(live_url)
        begin
          target.exec(IDENTITY_SQL).values.first == live.exec(IDENTITY_SQL).values.first
        ensure
          live.close
        end
      rescue PG::Error
        false
      end
    end
  end
end
