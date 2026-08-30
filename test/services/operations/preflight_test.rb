require "test_helper"

class Operations::PreflightTest < ActiveSupport::TestCase
  HealthySnapshot = Data.define(:checks)

  test "passes with safe prerequisites and never reads or reports environment values" do
    environment = Operations::Preflight::REQUIRED_ENVIRONMENT_NAMES.index_with { |name| "synthetic-#{name.downcase}" }
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
    Operations::Preflight::REQUIRED_ENVIRONMENT_NAMES.each do |name|
      assert_not_includes result.inspect, environment.fetch(name)
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
