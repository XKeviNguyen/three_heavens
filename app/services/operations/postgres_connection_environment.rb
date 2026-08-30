require "pg"

module Operations
  class PostgresConnectionEnvironment
    class InvalidConnection < StandardError; end

    def self.from_url(database_url)
      options = PG::Connection.conninfo_parse(database_url.to_s)
      environment = options.filter_map do |option|
        [ option[:envvar], option[:val].to_s ] if option[:envvar] && option.key?(:val)
      end.to_h
      raise InvalidConnection, "database connection is incomplete" if environment["PGDATABASE"].blank?

      environment
    rescue PG::Error, ArgumentError
      raise InvalidConnection, "database connection is invalid"
    end
  end
end
