require "test_helper"

class Operations::CommandRunnerTest < ActiveSupport::TestCase
  test "executes argument arrays without a shell and propagates generic failures" do
    runner = Operations::CommandRunner.new

    assert runner.call(environment: { "SYNTHETIC_SAFE_VALUE" => "value" }, arguments: [ "/usr/bin/true" ])
    error = assert_raises(Operations::CommandRunner::CommandFailed) do
      runner.call(environment: {}, arguments: [ "/usr/bin/false" ])
    end
    assert_equal "/usr/bin/false", error.program
    assert_equal 1, error.exit_status
  end

  test "rejects command strings and non-string environment values" do
    runner = Operations::CommandRunner.new
    assert_raises(ArgumentError) { runner.call(environment: {}, arguments: "true; unsafe") }
    assert_raises(ArgumentError) { runner.call(environment: { "SAFE" => 1 }, arguments: [ "/usr/bin/true" ]) }
  end
end
