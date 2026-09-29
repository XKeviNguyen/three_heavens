require "test_helper"

class ReadinessAndSecurityHeadersTest < ActionDispatch::IntegrationTest
  test "liveness remains independent from database readiness and providers" do
    original_check = ReadinessController.database_check
    ReadinessController.database_check = -> { raise "database must not be called" }
    begin
      get rails_health_check_path
    ensure
      ReadinessController.database_check = original_check
    end

    assert_response :success
    assert_not_includes response.body, "database must not be called"
  end

  test "readiness reports primary database availability without private details" do
    get readiness_check_path

    assert_response :success
    assert_equal "ready\n", response.body
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "readiness failure is generic" do
    error = ActiveRecord::ConnectionNotEstablished.new("private-db-host secret-password")

    original_check = ReadinessController.database_check
    ReadinessController.database_check = -> { raise error }
    begin
      get readiness_check_path
    ensure
      ReadinessController.database_check = original_check
    end

    assert_response :service_unavailable
    assert_equal "unavailable\n", response.body
    assert_not_includes response.body, "private-db-host"
    assert_not_includes response.body, "secret-password"
  end

  test "html responses enforce CSP and conservative security headers" do
    get login_path

    assert_response :success
    csp = response.headers.fetch("Content-Security-Policy")
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "object-src 'none'"
    assert_includes csp, "frame-ancestors 'none'"
    assert_includes csp, "form-action 'self'"
    assert_match(/script-src 'self' https:\/\/accounts\.google\.com\/gsi\/client 'nonce-[^']+';/i, csp)
    # Sign in with Google adds only path-scoped GIS sources, never wildcards.
    assert_match(/style-src 'self' https:\/\/accounts\.google\.com\/gsi\/style 'nonce-[^']+';/, csp)
    assert_includes csp, "connect-src 'self' https://accounts.google.com/gsi/;"
    assert_includes csp, "frame-src 'self' https://accounts.google.com/gsi/;"
    assert_not_includes csp, "*"
    assert_not_includes csp, "unsafe-eval"
    assert_not_includes csp, "unsafe-inline"
    assert_equal "DENY", response.headers["X-Frame-Options"]
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "strict-origin-when-cross-origin", response.headers["Referrer-Policy"]
    assert_includes response.headers["Permissions-Policy"], "camera=()"
  end
end
