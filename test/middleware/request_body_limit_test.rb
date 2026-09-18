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
end
