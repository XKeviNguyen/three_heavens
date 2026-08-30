require "test_helper"

class Operations::PostgresConnectionEnvironmentTest < ActiveSupport::TestCase
  test "translates a database URL into libpq environment variables without retaining the URL" do
    environment = Operations::PostgresConnectionEnvironment.from_url(
      "postgresql://restore_user:restore_password@restore.example.test:5433/isolated_restore?sslmode=require"
    )

    assert_equal "restore.example.test", environment["PGHOST"]
    assert_equal "5433", environment["PGPORT"]
    assert_equal "restore_user", environment["PGUSER"]
    assert_equal "restore_password", environment["PGPASSWORD"]
    assert_equal "isolated_restore", environment["PGDATABASE"]
    assert_equal "require", environment["PGSSLMODE"]
    assert_not environment.values.any? { |value| value.include?("postgresql://") }
  end

  test "rejects a database URL without a database name" do
    assert_raises(Operations::PostgresConnectionEnvironment::InvalidConnection) do
      Operations::PostgresConnectionEnvironment.from_url("postgresql://restore_user@restore.example.test")
    end
  end
end
