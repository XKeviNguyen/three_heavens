require "io/console"

module Accounts
  class ConsolePrompt
    def initialize(input: $stdin, output: $stdout)
      @input = input
      @output = output
    end

    def interactive?
      input.respond_to?(:tty?) && input.tty?
    end

    def ask(label)
      output.print label
      output.flush
      input.gets.to_s.chomp
    end

    def ask_secret(label)
      input.getpass(label).to_s
    end

    private

    attr_reader :input, :output
  end
end
