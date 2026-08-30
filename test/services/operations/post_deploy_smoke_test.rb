require "test_helper"

class Operations::PostDeploySmokeTest < ActiveSupport::TestCase
  Snapshot = Data.define(:checks)

  test "checks liveness readiness and generic dependencies without provider work" do
    requested_paths = []
    health = Snapshot.new(checks: [
      Operations::SystemHealth::Check.new(name: "primary_database", status: "healthy", metrics: {}),
      Operations::SystemHealth::Check.new(name: "queue_database", status: "healthy", metrics: {})
    ])

    result = Operations::PostDeploySmoke.call(
      base_url: "https://app.example.test",
      http_getter: ->(uri) { requested_paths << uri.path; 200 },
      system_health: -> { health }
    )

    assert result.successful?
    assert_equal %w[/up /ready], requested_paths
  end

  test "fails generically on endpoint or dependency failure and rejects credential URLs" do
    health = Snapshot.new(checks: [
      Operations::SystemHealth::Check.new(name: "active_storage", status: "unavailable", metrics: {})
    ])
    result = Operations::PostDeploySmoke.call(
      base_url: "https://app.example.test",
      http_getter: ->(uri) { uri.path == "/up" ? 200 : 503 },
      system_health: -> { health }
    )
    assert_not result.successful?

    assert_raises(ArgumentError) do
      Operations::PostDeploySmoke.call(base_url: "https://user:password@app.example.test")
    end
  end
end
