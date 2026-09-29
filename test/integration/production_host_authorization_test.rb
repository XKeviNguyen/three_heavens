require "test_helper"
require "json"
require "open3"

class ProductionHostAuthorizationTest < ActiveSupport::TestCase
  # Readiness is probed publicly with Host APP_HOST or from inside the
  # container over loopback; Kamal liveness (/up) is exempt; every other Host
  # stays refused for /ready and for application traffic.
  test "production authorizes only the public host, Kamal liveness, and loopback readiness probes" do
    script = <<~'RUBY'
      require "json"
      require "rack/mock"

      ReadinessController.database_check = -> { 1 }
      requests = {
        public_normal: [ "https://app.example.test/robots.txt", "app.example.test" ],
        public_readiness: [ "https://app.example.test/ready", "app.example.test" ],
        internal_normal: [ "http://10.0.0.42/robots.txt", "10.0.0.42" ],
        internal_liveness: [ "http://10.0.0.42/up", "10.0.0.42" ],
        internal_readiness: [ "http://10.0.0.42/ready", "10.0.0.42" ],
        loopback_readiness: [ "http://localhost:3000/ready", "localhost:3000" ],
        loopback_ipv4_readiness: [ "http://127.0.0.1:3000/ready", "127.0.0.1:3000" ],
        loopback_ipv6_readiness: [ "http://[::1]:3000/ready", "[::1]:3000" ],
        loopback_uppercase_readiness: [ "http://LOCALHOST:3000/ready", "LOCALHOST:3000" ],
        loopback_trailing_dot_readiness: [ "http://localhost.:3000/ready", "localhost.:3000" ],
        loopback_readiness_format: [ "http://localhost:3000/ready.txt", "localhost:3000" ],
        loopback_normal: [ "http://localhost:3000/robots.txt", "localhost:3000" ],
        malicious_readiness: [ "http://evil.example/ready", "evil.example" ],
        malicious_normal: [ "http://evil.example/robots.txt", "evil.example" ],
        malicious_liveness: [ "http://evil.example/up", "evil.example" ],
        empty_host_readiness: [ "http://10.0.0.42/ready", "" ]
      }
      statuses = requests.transform_values do |url, host|
        env = Rack::MockRequest.env_for(url, "HTTP_HOST" => host)
        status, = Rails.application.call(env)
        status
      end

      puts "HOST_AUTH_RESULTS=#{JSON.generate(statuses)}"
    RUBY
    environment = {
      "RAILS_ENV" => "production",
      "SECRET_KEY_BASE_DUMMY" => "1",
      "APP_HOST" => "app.example.test",
      "DATABASE_URL" => nil,
      "CACHE_DATABASE_URL" => nil,
      "QUEUE_DATABASE_URL" => nil,
      "CABLE_DATABASE_URL" => nil,
      "POSTGRES_USER" => nil,
      "POSTGRES_PASSWORD" => nil
    }

    stdout, stderr, status = Open3.capture3(
      environment,
      "bin/rails",
      "runner",
      script,
      chdir: Rails.root.to_s
    )

    assert status.success?, "production host test failed: #{stderr.lines.last}"
    result_line = stdout.lines.find { |line| line.start_with?("HOST_AUTH_RESULTS=") }
    assert result_line, "production host test did not report results"
    results = JSON.parse(result_line.delete_prefix("HOST_AUTH_RESULTS="))

    expected = {
      "public_normal" => 200, "public_readiness" => 200,
      "internal_normal" => 403, "internal_liveness" => 200, "internal_readiness" => 403,
      "loopback_readiness" => 200, "loopback_ipv4_readiness" => 200, "loopback_ipv6_readiness" => 200,
      "loopback_uppercase_readiness" => 200, "loopback_trailing_dot_readiness" => 403,
      "loopback_readiness_format" => 403, "loopback_normal" => 403,
      "malicious_readiness" => 403, "malicious_normal" => 403, "malicious_liveness" => 200,
      "empty_host_readiness" => 403
    }
    assert_equal expected, results
  end
end
