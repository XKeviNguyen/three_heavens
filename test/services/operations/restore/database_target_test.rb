require "test_helper"

class Operations::Restore::DatabaseTargetTest < ActiveSupport::TestCase
  class FakeResult
    def initialize(value)
      @value = value
    end

    def getvalue(*)
      value.to_s
    end

    def values
      [ value ]
    end

    private

    attr_reader :value
  end

  class FakeConnection
    attr_reader :closed

    def initialize(identity:, table_count:)
      @identity = identity
      @table_count = table_count
    end

    def exec(sql)
      sql.include?("current_database") ? FakeResult.new(identity) : FakeResult.new(table_count)
    end

    def close
      @closed = true
    end

    private

    attr_reader :identity, :table_count
  end

  class FakeConnector
    def initialize(connections)
      @connections = connections
    end

    def connect(url)
      connections.fetch(url)
    end

    private

    attr_reader :connections
  end

  test "accepts a distinct empty database" do
    target = FakeConnection.new(identity: [ "restore", "local", 5432 ], table_count: 0)
    live = FakeConnection.new(identity: [ "live", "local", 5432 ], table_count: 10)
    connector = FakeConnector.new("restore-url" => target, "live-url" => live)

    assert Operations::Restore::DatabaseTarget.new(
      target_url: "restore-url", live_url: "live-url", connector: connector
    ).validate!
    assert target.closed
    assert live.closed
  end

  test "rejects identical and non-empty targets" do
    target = FakeConnection.new(identity: [ "same", "local", 5432 ], table_count: 0)
    live = FakeConnection.new(identity: [ "same", "local", 5432 ], table_count: 10)
    connector = FakeConnector.new("restore-url" => target, "live-url" => live)
    assert_raises(Operations::Restore::DatabaseTarget::UnsafeDatabase) do
      Operations::Restore::DatabaseTarget.new(
        target_url: "restore-url", live_url: "live-url", connector: connector
      ).validate!
    end

    nonempty = FakeConnection.new(identity: [ "restore", "local", 5432 ], table_count: 1)
    other_live = FakeConnection.new(identity: [ "live", "local", 5432 ], table_count: 10)
    connector = FakeConnector.new("restore-url" => nonempty, "live-url" => other_live)
    assert_raises(Operations::Restore::DatabaseTarget::UnsafeDatabase) do
      Operations::Restore::DatabaseTarget.new(
        target_url: "restore-url", live_url: "live-url", connector: connector
      ).validate!
    end
  end

  test "rejects absent destination without falling back to live URL" do
    assert_raises(Operations::Restore::DatabaseTarget::UnsafeDatabase) do
      Operations::Restore::DatabaseTarget.new(target_url: nil, live_url: "live-url").validate!
    end
  end
end
