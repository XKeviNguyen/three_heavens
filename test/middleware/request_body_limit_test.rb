require "test_helper"

class RequestBodyLimitTest < ActiveSupport::TestCase
  test "allows the supported two-file upload plus multipart overhead" do
    called = false
    middleware = RequestBodyLimit.new(lambda { |_environment| called = true; [ 204, {}, [] ] })
    supported_length = (2 * SourceImports::Limits::MAX_UPLOAD_BYTES) +
      RequestBodyLimit::MULTIPART_OVERHEAD_BYTES

    assert_equal 204, middleware.call("CONTENT_LENGTH" => supported_length.to_s).first
    assert called
    assert_equal supported_length, RequestBodyLimit::MAX_BYTES
  end

  test "deployed proxy uses the same request ceiling" do
    deploy_line = Rails.root.join("config/deploy.yml").each_line.find { |line| line.include?("max_request_body:") }

    assert_equal RequestBodyLimit::MAX_BYTES, Integer(deploy_line.split.last.delete("_"), 10)
  end

  test "rejects declared oversized bodies before calling the application" do
    called = false
    middleware = RequestBodyLimit.new(lambda { |_environment| called = true; [ 200, {}, [] ] })

    status, headers, body = middleware.call("CONTENT_LENGTH" => (RequestBodyLimit::MAX_BYTES + 1).to_s)

    assert_equal 413, status
    assert_equal "no-store", headers.fetch("cache-control")
    assert_equal [ "Payload too large\n" ], body
    assert_not called
  end

  test "passes bounded and streaming requests through" do
    middleware = RequestBodyLimit.new(->(_environment) { [ 204, {}, [] ] })

    assert_equal 204, middleware.call("CONTENT_LENGTH" => RequestBodyLimit::MAX_BYTES.to_s).first
    assert_equal 204, middleware.call({}).first
  end

  test "wraps reads above and below the exception renderer" do
    stack = Rails.application.middleware.map(&:klass)
    positions = stack.each_index.select { |index| stack[index] == RequestBodyLimit }

    assert_equal 0, positions.first
    assert_equal stack.index(ActionDispatch::ShowExceptions) + 1, positions.last
  end

  test "returns 413 when a nested reader raises the exceeded error" do
    middleware = RequestBodyLimit.new(->(_environment) { raise RequestBodyLimit::ExceededError })

    status, headers, body = middleware.call({})

    assert_equal 413, status
    assert_equal "no-store", headers.fetch("cache-control")
    assert_equal [ "Payload too large\n" ], body
  end

  test "bounds undeclared streaming bodies while they are read" do
    middleware = RequestBodyLimit.new(lambda { |environment|
      environment.fetch("rack.input").read
      [ 204, {}, [] ]
    })
    oversized = StringIO.new("a" * (RequestBodyLimit::MAX_BYTES + 1))

    status, headers, body = middleware.call("rack.input" => oversized)

    assert_equal 413, status
    assert_equal "no-store", headers.fetch("cache-control")
    assert_equal [ "Payload too large\n" ], body
  end

  test "allows undeclared streaming bodies within the ceiling" do
    middleware = RequestBodyLimit.new(lambda { |environment|
      environment.fetch("rack.input").each { |_chunk| }
      [ 204, {}, [] ]
    })

    assert_equal 204, middleware.call("rack.input" => StringIO.new("Streamed body")).first
  end

  test "application stack returns 413 for an undeclared oversized multipart body" do
    boundary = "RequestBodyLimitTestBoundary"
    oversized = "--#{boundary}\r\n" \
      "Content-Disposition: form-data; name=\"source_file\"; filename=\"oversized.txt\"\r\n" \
      "Content-Type: text/plain\r\n\r\n" \
      "#{'a' * RequestBodyLimit::MAX_BYTES}\r\n" \
      "--#{boundary}--\r\n"

    status, headers, = Rails.application.call(undeclared_multipart_environment(oversized, boundary))

    assert_equal 413, status
    assert_equal "no-store", headers.fetch("cache-control")
  end

  test "application stack reads small undeclared multipart bodies normally" do
    boundary = "RequestBodyLimitTestBoundary"
    body = "--#{boundary}\r\n" \
      "Content-Disposition: form-data; name=\"source_text\"\r\n\r\n" \
      "Small enough\r\n" \
      "--#{boundary}--\r\n"

    status, = Rails.application.call(undeclared_multipart_environment(body, boundary))

    assert_not_equal 413, status
  end

  private

  def undeclared_multipart_environment(body, boundary)
    environment = Rack::MockRequest.env_for(
      "/translation_references",
      method: "POST",
      input: body,
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}",
      "HTTP_HOST" => "www.example.com"
    )
    environment.delete("CONTENT_LENGTH")
    environment
  end
end
