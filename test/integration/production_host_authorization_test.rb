require "test_helper"
require "json"
require "open3"

class ProductionHostAuthorizationTest < ActiveSupport::TestCase
  test "production authorizes the public host and exempts only Kamal liveness" do
    script = <<~'RUBY'
      require "json"
      require "rack/mock"

      requests = {
        public_normal: [ "https://app.example.test/robots.txt", "app.example.test" ],
        internal_normal: [ "http://10.0.0.42/robots.txt", "10.0.0.42" ],
        internal_liveness: [ "http://10.0.0.42/up", "10.0.0.42" ],
        internal_readiness: [ "http://10.0.0.42/ready", "10.0.0.42" ]
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

    assert_equal 200, results.fetch("public_normal")
    assert_equal 403, results.fetch("internal_normal")
    assert_equal 200, results.fetch("internal_liveness")
    assert_equal 403, results.fetch("internal_readiness")
  end
end
