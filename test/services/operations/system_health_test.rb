require "test_helper"

class Operations::SystemHealthTest < ActiveSupport::TestCase
  test "reports independent generic health and bounded metrics" do
    snapshot = Operations::SystemHealth.call(
      primary_check: -> { 1 },
      schema_check: -> { { pending_count: 0 } },
      cache_check: -> { raise "postgresql://user:password@private-cache" },
      queue_check: -> { { pending_count: 4, failed_count: 2, private_host: "secret" } },
      cable_check: -> { 1 },
      storage_check: -> { { configured: true, writable: false, status: "degraded", path: "/private/storage" } }
    )

    assert_equal "unavailable", snapshot.status
    assert_equal "unavailable", snapshot.checks.find { |check| check.name == "cache_database" }.status
    queue = snapshot.checks.find { |check| check.name == "queue_database" }
    assert_equal({ pending_count: 4, failed_count: 2 }, queue.metrics)
    storage = snapshot.checks.find { |check| check.name == "active_storage" }
    assert_equal "degraded", storage.status
    serialized = snapshot.inspect
    assert_not_includes serialized, "private-cache"
    assert_not_includes serialized, "/private/storage"
    assert_not_includes serialized, "secret"
  end

  test "reports healthy when all dependencies succeed" do
    snapshot = Operations::SystemHealth.call(
      primary_check: -> { 1 },
      schema_check: -> { { pending_count: 0 } },
      cache_check: -> { 1 },
      queue_check: -> { { pending_count: 0, failed_count: 0 } },
      cable_check: -> { 1 },
      storage_check: -> { { configured: true, writable: true } }
    )

    assert_equal "healthy", snapshot.status
    assert snapshot.checks.all? { |check| check.status == "healthy" }
  end
end
