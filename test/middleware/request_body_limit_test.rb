require "test_helper"

class RequestBodyLimitTest < ActiveSupport::TestCase
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
