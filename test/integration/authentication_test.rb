require "test_helper"

class AuthenticationTest < ActionDispatch::IntegrationTest
  test "login accepts normalized email and regenerates the session" do
    get history_path
    cookie_before = cookies[session_cookie_name]

    submit_login session: {
      email: "  USER@EXAMPLE.TEST ",
      password: "correct horse battery staple"
    }

    assert_redirected_to history_path
    assert_not_equal cookie_before, cookies[session_cookie_name]
    follow_redirect!
    assert_response :success
    assert_select "header", text: /user@example\.test/
  end

  test "bad password and unknown account return the same safe error" do
    alerts = [
      [ "user@example.test", "incorrect password value" ],
      [ "unknown@example.test", "incorrect password value" ]
    ].map do |email, password|
      submit_login session: { email: email, password: password }

      assert_response :unprocessable_content
      assert_select "header", text: /user@example\.test/, count: 0
      css_select("[role='alert']").first.text.strip
    end

    assert_equal [ SessionsController::INVALID_CREDENTIALS_MESSAGE ] * 2, alerts
  end

  test "login attempts are rate limited by remote IP" do
    SessionsController::LOGIN_RATE_LIMIT.times do
      submit_login session: {
        email: "unknown@example.test",
        password: "incorrect password value"
      }
      assert_response :unprocessable_content
    end

    submit_login session: {
      email: "unknown@example.test",
      password: "incorrect password value"
    }

    assert_response :too_many_requests
    assert_equal SessionsController::LOGIN_RATE_LIMIT_WINDOW.to_i.to_s, response.headers["Retry-After"]
    assert_select "[role='alert']", text: /Too many sign-in attempts/
    assert_select "h1", "Sign in"
    assert_not_authenticated
  end

  test "missing session parameters are rejected safely" do
    submit_login({})

    assert_bad_login_request
  end

  test "scalar session parameters are rejected safely" do
    submit_login session: "malformed"

    assert_bad_login_request
  end

  test "array session parameters are rejected safely" do
    submit_login session: [ "malformed" ]

    assert_bad_login_request
  end

  test "nested email arrays and hashes are rejected safely" do
    [ [ "user@example.test" ], { value: "user@example.test" } ].each do |email|
      submit_login session: { email: email, password: "incorrect password value" }

      assert_bad_login_request
    end
  end

  test "nested password arrays and hashes are rejected safely" do
    [ [ "incorrect password value" ], { value: "incorrect password value" } ].each do |password|
      submit_login session: { email: "user@example.test", password: password }

      assert_bad_login_request
    end
  end

  test "unexpected authentication attributes are rejected instead of assigned" do
    submit_login session: {
      email: "user@example.test",
      password: "correct horse battery staple",
      role: "admin",
      status: "active",
      user_id: users(:admin).id
    }

    assert_bad_login_request
  end

  test "oversized email is rejected before authentication" do
    assert_authentication_not_invoked do
      submit_login session: {
        email: "a" * (User::MAXIMUM_EMAIL_LENGTH + 1),
        password: "incorrect password value"
      }
    end

    assert_invalid_credentials
    assert_select "input[name='session[email]'][value]", count: 0
    assert_not_authenticated
  end

  test "oversized password is rejected before authentication without account disclosure" do
    oversized_password = "a" * (User::MAXIMUM_PASSWORD_LENGTH + 1)

    [ "user@example.test", "unknown@example.test" ].each do |email|
      assert_authentication_not_invoked do
        submit_login session: { email: email, password: oversized_password }
      end

      assert_invalid_credentials
      assert_select "input[name='session[email]'][value=?]", email
      assert_not_authenticated
    end
  end

  test "failed login safely redisplays a scalar email" do
    submit_login session: {
      email: "person@example.test",
      password: "incorrect password value"
    }

    assert_invalid_credentials
    assert_select "input[name='session[email]'][value=?]", "person@example.test"
    assert_not_authenticated
  end

  test "malformed login parameters cannot break the login view" do
    get login_path, params: { session: "malformed" }

    assert_response :success
    assert_select "h1", "Sign in"
    assert_select "input[name='session[email]'][value='']"

    submit_login session: "malformed"

    assert_response :bad_request
    assert_select "h1", "Sign in"
    assert_select "input[name='session[email]'][value='']"
  end

  test "logout clears authentication" do
    sign_in_as users(:normal)

    delete session_path

    assert_redirected_to login_path
    get history_path
    assert_redirected_to login_path
  end

  test "protected pages require authentication" do
    get root_path

    assert_redirected_to login_path
    follow_redirect!
    assert_select "h1", "Sign in"
  end

  test "session cookie configuration is HTTP-only and same-site protected" do
    options = Rails.application.config.session_options

    assert options[:httponly]
    assert_equal :lax, options[:same_site]
    assert_equal Rails.env.production?, options[:secure]
  end

  private

  def assert_authentication_not_invoked(&block)
    authentication_invoked = false
    authentication_owner = User.method(:authenticate_by_email).owner
    trace = TracePoint.new(:call) do |event|
      if event.defined_class == authentication_owner && event.method_id == :authenticate_by_email
        authentication_invoked = true
      end
    end

    trace.enable(&block)

    refute authentication_invoked, "User.authenticate_by_email must not be invoked"
  end

  def submit_login(parameters)
    post session_path, params: parameters, headers: login_rate_limit_headers
  end

  def assert_bad_login_request
    assert_response :bad_request
    assert_select "[role='alert']", text: /email or password is incorrect/
    assert_select "h1", "Sign in"
    assert_not_authenticated
  end

  def assert_invalid_credentials
    assert_response :unprocessable_content
    assert_select "[role='alert']", text: /email or password is incorrect/
  end

  def assert_not_authenticated
    get root_path
    assert_redirected_to login_path
  end

  def session_cookie_name
    Rails.application.config.session_options.fetch(:key)
  end
end
