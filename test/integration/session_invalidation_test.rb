require "test_helper"

class SessionInvalidationTest < ActionDispatch::IntegrationTest
  test "a session cookie copied before sign-out stops authenticating after sign-out" do
    sign_in_as users(:normal)
    copied_cookie = session_cookie

    assert_cookie_authenticates copied_cookie

    sign_out
    assert_redirected_to login_path

    assert_cookie_does_not_authenticate copied_cookie
    assert_not users(:normal).sessions.exists?
  end

  test "signing out one browser leaves the account's other browsers signed in" do
    laptop = open_session
    phone = open_session
    [ laptop, phone ].each do |device|
      device.post session_path,
                  params: { session: { email: "user@example.test", password: "correct horse battery staple" } },
                  headers: { "REMOTE_ADDR" => "2001:db8::1" }
      device.assert_redirected_to new_translation_workspace_path
    end
    assert_equal 2, users(:normal).sessions.count

    laptop.delete session_path

    laptop.get history_path
    laptop.assert_redirected_to login_path
    phone.get history_path
    phone.assert_response :success
    assert_equal 1, users(:normal).sessions.count
  end

  test "signing in again rotates the cookie and ends the replaced server session" do
    sign_in_as users(:normal)
    first_cookie = session_cookie

    sign_in_as users(:other)

    assert_not_equal first_cookie, session_cookie
    assert_equal users(:other).id, signed_in_user_id
    assert_not users(:normal).sessions.exists?
    assert_cookie_does_not_authenticate first_cookie
  end

  test "a cookie whose server session is gone is cleared on the next request" do
    sign_in_as users(:normal)
    users(:normal).sessions.delete_all

    get history_path

    assert_redirected_to login_path
    assert_nil session[:authentication_session_id]
  end

  test "a disabled account's existing session no longer authenticates" do
    sign_in_as users(:normal)
    users(:normal).update!(status: "disabled")

    get history_path

    assert_redirected_to login_path
  end

  private

  def session_cookie
    cookies[session_cookie_name]
  end

  def assert_cookie_authenticates(cookie_value)
    replay = replay_session(cookie_value)
    replay.get history_path
    replay.assert_response :success
  end

  def assert_cookie_does_not_authenticate(cookie_value)
    replay = replay_session(cookie_value)
    replay.get history_path
    replay.assert_redirected_to login_path
  end

  def replay_session(cookie_value)
    open_session.tap { |replay| replay.cookies[session_cookie_name] = cookie_value }
  end

  def session_cookie_name
    Rails.application.config.session_options.fetch(:key)
  end
end
