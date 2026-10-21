require "test_helper"

class Operations::PostDeploySmokeTest < ActiveSupport::TestCase
  Snapshot = Data.define(:checks)

  test "checks liveness readiness and generic dependencies without provider work" do
    requested_paths = []
    health = Snapshot.new(checks: [
      Operations::SystemHealth::Check.new(name: "primary_database", status: "healthy", metrics: {}),
      Operations::SystemHealth::Check.new(name: "queue_database", status: "healthy", metrics: {})
    ])

    result = Operations::PostDeploySmoke.call(
      base_url: "https://app.example.test",
      http_getter: ->(uri) { requested_paths << uri.path; 200 },
      system_health: -> { health }
    )

    assert result.successful?
    assert_equal %w[/up /ready], requested_paths
  end

  # The real HTTP getter, against a loopback server that records each request:
  # the header it sends is the one the integration test proves /up accepts.
  test "requests each endpoint with the Accept header that /up and /ready serve" do
    server = TCPServer.new("127.0.0.1", 0)
    accepts = Queue.new
    responder = Thread.new do
      2.times do
        client = server.accept
        headers = []
        while (line = client.gets) && line != "\r\n"
          headers << line
        end
        accepts << headers.find { |header| header.downcase.start_with?("accept:") }.to_s.split(":", 2).last.to_s.strip
        client.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        client.close
      end
    end

    result = Operations::PostDeploySmoke.call(
      base_url: "http://127.0.0.1:#{server.addr[1]}",
      allow_http: true,
      system_health: -> { Snapshot.new(checks: []) }
    )
    responder.join(5)

    assert result.successful?
    assert_equal [ Operations::PostDeploySmoke::ACCEPT ] * 2, Array.new(2) { accepts.pop(timeout: 1) }
  ensure
    responder&.kill
    server&.close
  end

  test "fails generically on endpoint or dependency failure and rejects credential URLs" do
    health = Snapshot.new(checks: [
      Operations::SystemHealth::Check.new(name: "active_storage", status: "unavailable", metrics: {})
    ])
    result = Operations::PostDeploySmoke.call(
      base_url: "https://app.example.test",
      http_getter: ->(uri) { uri.path == "/up" ? 200 : 503 },
      system_health: -> { health }
    )
    assert_not result.successful?

    assert_raises(ArgumentError) do
      Operations::PostDeploySmoke.call(base_url: "https://user:password@app.example.test")
    end
  end
end
