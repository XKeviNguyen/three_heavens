module Operations
  class CommandRunner
    class CommandFailed < StandardError
      attr_reader :program, :exit_status

      def initialize(program:, exit_status: nil)
        @program = program
        @exit_status = exit_status
        super("#{program} failed#{" with exit status #{exit_status}" if exit_status}")
      end
    end

    def call(environment:, arguments:)
      validate!(environment, arguments)
      child_environment = {
        "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
        "LANG" => ENV.fetch("LANG", "C.UTF-8")
      }.merge(environment)
      process_id = Process.spawn(
        child_environment,
        *arguments,
        out: File::NULL,
        err: File::NULL,
        unsetenv_others: true
      )
      _process_id, status = Process.wait2(process_id)
      raise CommandFailed.new(program: arguments.first, exit_status: status.exitstatus) unless status.success?

      true
    rescue Errno::ENOENT
      raise CommandFailed.new(program: arguments.first)
    end

    private

    def validate!(environment, arguments)
      raise ArgumentError, "command arguments must be a non-empty array" unless arguments.is_a?(Array) && arguments.any?
      raise ArgumentError, "command environment must be a hash" unless environment.is_a?(Hash)
      raise ArgumentError, "command arguments must be strings" unless arguments.all? { |argument| argument.is_a?(String) }
      raise ArgumentError, "command environment must contain strings" unless environment.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
    end
  end
end
