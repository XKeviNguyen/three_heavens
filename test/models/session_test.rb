require "test_helper"
require "timeout"

# Two real database connections order a sign-in against a disable of the
# same account: whichever holds the account row first, no session survives.
class SessionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # The test thread waits on the others; letting them load code meanwhile
  # avoids a deadlock on the autoload interlock.
  def run(...)
    ActiveSupport::Dependencies.interlock.permit_concurrent_loads { super }
  end

  setup do
    @user = User.create!(email: "session-race-#{SecureRandom.hex(4)}@example.test", password: "correct horse battery staple",
                         role: :user, status: :active, email_verified_at: Time.current, locale: "en")
  end

  teardown { @user.destroy! }

  test "a sign-in waits for a disable in progress and then starts no session" do
    disabling = Queue.new
    commit = Queue.new
    disable = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.find(@user.id).update!(status: "disabled")
          disabling << true
          commit.pop
        end
      end
    end
    Timeout.timeout(20) { disabling.pop }

    sign_in = Thread.new { ActiveRecord::Base.connection_pool.with_connection { Session.start(@user) } }
    wait_until_blocked_on_a_lock
    commit << true

    assert disable.join(20)
    assert_nil sign_in.value
    assert_not Session.exists?(user_id: @user.id)
  ensure
    commit << true
  end

  test "a disable that waits for a sign-in in progress deletes the session it started" do
    started = Queue.new
    commit = Queue.new
    sign_in = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Session.transaction do
          Session.start(@user).tap do
            started << true
            commit.pop
          end
        end
      end
    end
    Timeout.timeout(20) { started.pop }

    disable = Thread.new { ActiveRecord::Base.connection_pool.with_connection { User.find(@user.id).update!(status: "disabled") } }
    wait_until_blocked_on_a_lock
    commit << true

    assert sign_in.value
    assert disable.join(20)
    assert_not Session.exists?(user_id: @user.id)
  ensure
    commit << true
  end

  private

  # Polls PostgreSQL until another backend is waiting for a lock.
  def wait_until_blocked_on_a_lock
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until ActiveRecord::Base.uncached { ActiveRecord::Base.connection.select_value(<<~SQL) }.to_i.positive?
      SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'
    SQL
      flunk "no backend waited for the account row" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      Thread.pass
    end
  end
end
