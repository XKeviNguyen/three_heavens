require "test_helper"

class Operations::PreflightTest < ActiveSupport::TestCase
  HealthySnapshot = Data.define(:checks)
  SYNTHETIC_GOOGLE_CLIENT_ID = "123456789012-preflightsynthetic.apps.googleusercontent.com"

  test "default migration check uses the real primary connection pool" do
    result = Operations::Preflight.call(
      environment: {},
      system_health: -> { HealthySnapshot.new(checks: []) },
      executable_finder: ->(*) { true },
      recurring_validator: ->(*) { true },
      eager_load_check: -> { true }
    )

    assert_equal "healthy", result.checks.find { |check| check.name == "schema_migrations" }.status
  end

  test "passes with safe prerequisites and never reads or reports environment values" do
    environment = Operations::Preflight::REQUIRED_ENVIRONMENT_NAMES.index_with { |name| "synthetic-#{name.downcase}" }
    environment["GOOGLE_CLIENT_ID"] = SYNTHETIC_GOOGLE_CLIENT_ID
    health = HealthySnapshot.new(
      checks: %w[primary_database cache_database queue_database cable_database active_storage].map do |name|
        Operations::SystemHealth::Check.new(name: name, status: "healthy", metrics: {})
      end
    )

    result = Operations::Preflight.call(
      environment: environment,
      system_health: -> { health },
      executable_finder: ->(_name) { true },
      migration_check: -> { true },
      recurring_path: Rails.root.join("config/recurring.yml"),
      recurring_validator: ->(*) { true },
      queue_adapter: -> { "solid_queue" },
      eager_load_check: -> { true }
    )

    assert result.successful?, result.checks.inspect
    assert result.checks.all? { |check| check.status == "healthy" }
    environment.each_value { |value| assert_not_includes result.inspect, value }
  end

  test "a deployment without a valid Google OAuth client ID fails preflight by name" do
    healthy = HealthySnapshot.new(checks: [])
    base = Operations::Preflight::REQUIRED_ENVIRONMENT_NAMES.index_with { |name| "synthetic-#{name.downcase}" }

    [ nil, "", "not-a-client-id", "GOCSPX-synthetic-client-secret" ].each do |client_id|
      result = Operations::Preflight.call(
        environment: base.merge("GOOGLE_CLIENT_ID" => client_id).compact,
        system_health: -> { healthy }, executable_finder: ->(_name) { true }, migration_check: -> { true },
        recurring_validator: ->(*) { true }, queue_adapter: -> { "solid_queue" }, eager_load_check: -> { true }
      )

      assert_not result.successful?, client_id.inspect
      assert_equal [ "google_client_id" ], result.checks.reject { |check| check.status == "healthy" || check.name == "storage_write_probe" }.map(&:name)
      assert_not_includes result.inspect, client_id.to_s if client_id.present?
    end
  end

  test "fails when environment database storage or tooling is unavailable" do
    health = HealthySnapshot.new(
      checks: [
        Operations::SystemHealth::Check.new(name: "primary_database", status: "unavailable", metrics: {}),
        Operations::SystemHealth::Check.new(name: "active_storage", status: "unavailable", metrics: {})
      ]
    )
    result = Operations::Preflight.call(
      environment: {},
      system_health: -> { health },
      executable_finder: ->(name) { name == "pg_restore" },
      migration_check: -> { false },
      recurring_validator: ->(*) { true },
      queue_adapter: -> { "async" },
      eager_load_check: -> { true }
    )

    assert_not result.successful?
    assert_equal "unavailable", result.checks.find { |check| check.name == "required_environment" }.status
    assert_equal "unavailable", result.checks.find { |check| check.name == "pg_dump" }.status
    assert_equal "unavailable", result.checks.find { |check| check.name == "primary_database" }.status
  end
end
