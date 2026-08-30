require "test_helper"

class Operations::Restore::LocalDrillTest < ActiveSupport::TestCase
  test "requires unmistakable explicit intent before creating disposable resources" do
    error = assert_raises(Operations::Restore::LocalDrill::UnsafeDrill) do
      Operations::Restore::LocalDrill.call(environment: {})
    end

    assert_includes error.message, Operations::Restore::LocalDrill::CONFIRMATION_NAME

    error = assert_raises(Operations::Restore::LocalDrill::UnsafeDrill) do
      Operations::Restore::LocalDrill.call(
        environment: {
          Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1",
          "DATABASE_URL" => "postgresql://synthetic-production-marker"
        }
      )
    end
    assert_includes error.message, "production-marked"
  end
end
