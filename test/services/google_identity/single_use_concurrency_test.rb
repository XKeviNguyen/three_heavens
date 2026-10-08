require "test_helper"

module GoogleIdentity
  # A Google ceremony and a pending sign-in are each accepted exactly once,
  # even when several application processes receive them at the same instant.
  # Each consumer here is a separate forked process with its own database
  # connection, released together, so the outcome rests on PostgreSQL alone.
  class SingleUseConcurrencyTest < ActiveSupport::TestCase
    self.use_transactional_tests = false
    CONSUMERS = 6
    ROUNDS = 5

    teardown { ConsumedNonce.delete_all }

    test "simultaneous consumers of one ceremony: exactly one succeeds, every round" do
      ROUNDS.times do
        token = Ceremony.issue(intent: "sign_in", locale: "en", appearance: "system")

        assert_equal 1, simultaneous_successes { Ceremony.resolve(token).consume! }
        assert_not Ceremony.resolve(token).consume!
      end
    end

    test "simultaneous completions of one pending sign-in: exactly one succeeds, every round" do
      user = User.find_by!(email: "user@example.test")
      ROUNDS.times do
        jar = cookie_jar
        PendingSignIn.store(jar, user:, ceremony: Ceremony.resolve(Ceremony.issue(intent: "sign_in", locale: "en", appearance: "system")))
        stored = jar[PendingSignIn::COOKIE]

        assert_equal 1, simultaneous_successes { PendingSignIn.take(cookie_jar(stored))&.user_id == user.id }
        assert_nil PendingSignIn.take(cookie_jar(stored))
      end
    end

    private

    def cookie_jar(pending = nil)
      environment = Rails.application.env_config.merge("HTTP_HOST" => "www.example.com")
      environment["HTTP_COOKIE"] = "#{PendingSignIn::COOKIE}=#{CGI.escape(pending)}" if pending
      ActionDispatch::Request.new(environment).cookie_jar
    end

    # Forks the consumers, releases them at once, and counts true results.
    def simultaneous_successes(&consume)
      start_reader, start_writer = IO.pipe
      results = CONSUMERS.times.map do
        result_reader, result_writer = IO.pipe
        pid = fork do
          start_writer.close
          result_reader.close
          ActiveRecord::Base.connection.verify!
          start_reader.read(1)
          result_writer.write(consume.call ? "1" : "0")
          result_writer.close
          exit!(0)
        end
        result_writer.close
        [ pid, result_reader ]
      end
      start_reader.close
      start_writer.write("go" * CONSUMERS)
      start_writer.close
      outcomes = results.map do |pid, reader|
        Process.wait(pid)
        reader.read.tap { reader.close }
      end
      assert_equal CONSUMERS, outcomes.count { |outcome| %w[0 1].include?(outcome) }, "every consumer reports"
      outcomes.count("1")
    end
  end
end
