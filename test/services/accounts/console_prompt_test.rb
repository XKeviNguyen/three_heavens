require "test_helper"

class Accounts::ConsolePromptTest < ActiveSupport::TestCase
  class ScriptedConsole
    attr_reader :getpass_labels

    def initialize(tty: true, lines: [], secrets: [])
      @tty = tty
      @lines = lines
      @secrets = secrets
      @getpass_labels = []
    end

    def tty?
      @tty
    end

    def gets
      @lines.shift
    end

    def getpass(label)
      getpass_labels << label
      @secrets.shift
    end
  end

  test "reads visible input through gets and secret input through getpass" do
    console = ScriptedConsole.new(lines: [ "operator@example.test\n" ], secrets: [ "supplied secret" ])
    output = StringIO.new
    prompt = Accounts::ConsolePrompt.new(input: console, output: output)

    assert prompt.interactive?
    assert_equal "operator@example.test", prompt.ask("Admin email: ")
    assert_equal "supplied secret", prompt.ask_secret("Admin password: ")
    assert_equal "Admin email: ", output.string
    assert_equal [ "Admin password: " ], console.getpass_labels
  end

  test "reports non-interactive input" do
    prompt = Accounts::ConsolePrompt.new(
      input: ScriptedConsole.new(tty: false),
      output: StringIO.new
    )

    assert_not prompt.interactive?
  end
end
