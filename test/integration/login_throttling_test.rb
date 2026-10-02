require "test_helper"

# Production requests reach Puma through kamal-proxy and then Thruster in the
# app container, so REMOTE_ADDR is Thruster's loopback address and each proxy
# appends its peer to X-Forwarded-For. These examples replay that header shape
# with documentation addresses; the proxies themselves are not exercised here.
class LoginThrottlingTest < ActionDispatch::IntegrationTest
  THRUSTER_ADDRESS = "127.0.0.1"
  KAMAL_PROXY_ADDRESS = "172.18.0.2"

  test "rotating spoofed X-Forwarded-For entries behind the proxies does not reset the client's budget" do
    client = "198.51.100.7"

    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      attempt_login "unknown-#{attempt}@example.test", from: client, spoofed: "203.0.113.#{attempt + 1}"
      assert_response :unprocessable_content
      assert_equal client, request.remote_ip
    end

    attempt_login "unknown-final@example.test", from: client, spoofed: "203.0.113.200"
    assert_response :too_many_requests
    assert_equal client, request.remote_ip
  end

  test "spoofed private and loopback entries cannot impersonate a trusted proxy hop" do
    client = "198.51.100.8"

    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      attempt_login "unknown-#{attempt}@example.test", from: client, spoofed: "10.0.0.#{attempt + 1}, 127.0.0.1"
      assert_response :unprocessable_content
    end

    attempt_login "unknown-final@example.test", from: client, spoofed: "192.168.0.1"
    assert_response :too_many_requests
  end

  test "distinct clients behind the proxies keep independent budgets" do
    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      attempt_login "unknown-#{attempt}@example.test", from: "198.51.100.9"
    end
    attempt_login "unknown-a@example.test", from: "198.51.100.9"
    assert_response :too_many_requests

    attempt_login "unknown-b@example.test", from: "198.51.100.10"
    assert_response :unprocessable_content
    assert_equal "198.51.100.10", request.remote_ip
  end

  test "headers a client fully controls cannot buy more guesses against one account" do
    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      post session_path,
           params: { session: { email: "user@example.test", password: "incorrect password value" } },
           headers: { "REMOTE_ADDR" => THRUSTER_ADDRESS, "X-Forwarded-For" => "203.0.113.#{attempt + 1}" }
      assert_response :unprocessable_content
      assert_equal "203.0.113.#{attempt + 1}", request.remote_ip
    end

    post session_path,
         params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
         headers: { "REMOTE_ADDR" => THRUSTER_ADDRESS, "X-Forwarded-For" => "203.0.113.99" }

    assert_response :too_many_requests
    assert_nil signed_in_user_id
  end

  test "the account budget is shared by every spelling of the same email" do
    spellings = [ "user@example.test", "USER@example.test", "  User@Example.Test " ]

    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      post session_path,
           params: { session: { email: spellings[attempt % spellings.size], password: "incorrect password value" } },
           headers: { "REMOTE_ADDR" => "2001:db8:#{attempt + 1}::1" }
      assert_response :unprocessable_content
    end

    post session_path,
         params: { session: { email: "uSeR@example.test", password: "correct horse battery staple" } },
         headers: { "REMOTE_ADDR" => "2001:db8:ff::1" }
    assert_response :too_many_requests
    assert_nil signed_in_user_id
  end

  test "an exhausted account budget does not block other accounts" do
    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      post session_path,
           params: { session: { email: "user@example.test", password: "incorrect password value" } },
           headers: { "REMOTE_ADDR" => "2001:db8:#{attempt + 1}::1" }
    end

    post session_path,
         params: { session: { email: "other@example.test", password: "other secure password value" } },
         headers: { "REMOTE_ADDR" => "2001:db8:ff::1" }

    assert_redirected_to new_translation_workspace_path
    assert_equal users(:other).id, signed_in_user_id
  end

  test "a Client-Ip header neither chooses the client address nor fails the request" do
    post session_path,
         params: { session: { email: "user@example.test", password: "incorrect password value" } },
         headers: {
           "REMOTE_ADDR" => THRUSTER_ADDRESS,
           "X-Forwarded-For" => "198.51.100.11, #{KAMAL_PROXY_ADDRESS}",
           "Client-Ip" => "203.0.113.50"
         }
    assert_response :unprocessable_content
    assert_equal "198.51.100.11", request.remote_ip

    post session_path,
         params: { session: { email: "user@example.test", password: "incorrect password value" } },
         headers: { "REMOTE_ADDR" => THRUSTER_ADDRESS, "Client-Ip" => "203.0.113.51" }
    assert_response :unprocessable_content
    assert_equal THRUSTER_ADDRESS, request.remote_ip
  end

  test "IPv6 clients share their /64's budget" do
    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      attempt_login "unknown-#{attempt}@example.test", from: "2001:db8:abcd:1::#{attempt + 1}"
      assert_response :unprocessable_content
    end

    attempt_login "unknown-final@example.test", from: "2001:db8:abcd:1:ffff::1"
    assert_response :too_many_requests

    attempt_login "unknown-other@example.test", from: "2001:db8:abcd:2::1"
    assert_response :unprocessable_content
  end

  test "IPv4-mapped IPv6 clients keep their own IPv4 budget" do
    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      attempt_login "unknown-#{attempt}@example.test", from: "::ffff:198.51.100.20"
    end
    attempt_login "unknown-final@example.test", from: "198.51.100.20"
    assert_response :too_many_requests

    attempt_login "unknown-other@example.test", from: "::ffff:198.51.100.21"
    assert_response :unprocessable_content
  end

  test "failed attempts from elsewhere do not lock the owner out of a browser that signed in before" do
    owner = open_session
    owner.post session_path,
               params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
               headers: { "REMOTE_ADDR" => "198.51.100.30" }
    owner.assert_redirected_to new_translation_workspace_path
    owner.delete session_path

    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      post session_path,
           params: { session: { email: "user@example.test", password: "incorrect password value" } },
           headers: { "REMOTE_ADDR" => "203.0.113.#{attempt + 1}" }
    end
    post session_path,
         params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
         headers: { "REMOTE_ADDR" => "203.0.113.99" }
    assert_response :too_many_requests

    owner.post session_path,
               params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
               headers: { "REMOTE_ADDR" => "198.51.100.30" }
    owner.assert_redirected_to new_translation_workspace_path
  end

  test "a device cookie for one account gives no separate budget for another" do
    sign_in_as users(:other)
    sign_out

    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      post session_path,
           params: { session: { email: "user@example.test", password: "incorrect password value" } },
           headers: { "REMOTE_ADDR" => "203.0.113.#{attempt + 1}" }
    end
    post session_path,
         params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
         headers: { "REMOTE_ADDR" => "203.0.113.99" }

    assert_response :too_many_requests
    assert_nil signed_in_user_id
  end

  test "an unparseable client address is still throttled rather than failing" do
    SessionsController::LOGIN_RATE_LIMIT.times do |attempt|
      post session_path,
           params: { session: { email: "unknown-#{attempt}@example.test", password: "incorrect password value" } },
           headers: { "REMOTE_ADDR" => "garbage" }
      assert_response :unprocessable_content
    end
    post session_path,
         params: { session: { email: "unknown-final@example.test", password: "incorrect password value" } },
         headers: { "REMOTE_ADDR" => "garbage" }
    assert_response :too_many_requests
  end

  test "over-long and NUL-containing emails are refused as invalid credentials" do
    [ "user\u0000@example.test", "#{"a" * 250}@example.test" ].each_with_index do |email, attempt|
      post session_path,
           params: { session: { email: email, password: "correct horse battery staple" } },
           headers: { "REMOTE_ADDR" => "198.51.100.#{40 + attempt}" }
      assert_response :unprocessable_content
      assert_nil signed_in_user_id
    end
  end

  private

  def attempt_login(email, from:, spoofed: nil)
    forwarded_for = [ spoofed, from, KAMAL_PROXY_ADDRESS ].compact.join(", ")
    post session_path,
         params: { session: { email: email, password: "incorrect password value" } },
         headers: { "REMOTE_ADDR" => THRUSTER_ADDRESS, "X-Forwarded-For" => forwarded_for }
  end
end
