require "test_helper"

class Operations::Restore::LocalDrillTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

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

  test "loads the SQL schema and completes a disposable database and storage restore" do
    result = Operations::Restore::LocalDrill.call(
      environment: { Operations::Restore::LocalDrill::CONFIRMATION_NAME => "1" }
    )

    assert_equal 1, result.blob_count
    assert_equal 1, result.attachment_count
    assert_equal 1, result.document_count
    assert_equal 0, result.critical_count
  end
end
