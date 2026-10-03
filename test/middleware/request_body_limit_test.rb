require "test_helper"

class RequestBodyLimitTest < ActiveSupport::TestCase
  test "allows the supported two-file upload plus multipart overhead" do
    called = false
    middleware = RequestBodyLimit.new(lambda { |_environment| called = true; [ 204, {}, [] ] })
    supported_length = (2 * SourceImports::Limits::MAX_UPLOAD_BYTES) +
      RequestBodyLimit::MULTIPART_OVERHEAD_BYTES

    assert_equal 204, middleware.call(upload_environment("CONTENT_LENGTH" => supported_length.to_s)).first
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

    assert_equal 204, middleware.call(upload_environment("CONTENT_LENGTH" => RequestBodyLimit::MAX_BYTES.to_s)).first
    assert_equal 204, middleware.call({}).first
  end

  test "ordinary requests get the small default limit, uploads and long-text forms only by explicit route" do
    middleware = RequestBodyLimit.new(->(_environment) { [ 204, {}, [] ] })
    default = RequestBodyLimit::DEFAULT_MAX_BYTES
    long_text = RequestBodyLimit::LONG_TEXT_MAX_BYTES
    upload = RequestBodyLimit::MAX_BYTES
    status = ->(method, path, length) { middleware.call("REQUEST_METHOD" => method, "PATH_INFO" => path, "CONTENT_LENGTH" => length.to_s).first }

    # Unknown, unrouted, and ordinary authenticated routes, however spelled.
    %w[/ /projects /projects/1 /nonexistent /glossaries/1/activate /settings/models //workflow_profiles/ /experiments/1/retry_failed.json].each do |path|
      assert_equal 204, status.call("POST", path, default), path
      assert_equal 413, status.call("POST", path, default + 1), path
    end
    # Long-text forms: whole documents and glossaries, never files.
    %w[/translation_workspace /translation_workspace/options /final_translations/7/save_revision /glossaries /glossaries/3
       /methodology_profiles /methodology_profiles/4 /workspace_terminology //glossaries/3/ /translation_workspace.html].each do |path|
      assert_equal 204, status.call("POST", path, long_text), path
      assert_equal 413, status.call("POST", path, long_text + 1), path
    end
    # Upload forms: two supported files plus multipart overhead.
    %w[/source_imports /translation_references /translation_references/9 //source_imports/].each do |path|
      %w[POST PATCH PUT].each do |method|
        assert_equal 204, status.call(method, path, upload), "#{method} #{path}"
        assert_equal 413, status.call(method, path, upload + 1), "#{method} #{path}"
      end
    end
    # A large allowance never extends to methods that do not submit forms,
    # nor to look-alike paths.
    assert_equal 413, status.call("GET", "/source_imports", default + 1)
    assert_equal 413, status.call("DELETE", "/translation_references/9", default + 1)
    assert_equal 413, status.call("POST", "/source_imports/9", default + 1)
    assert_equal 413, status.call("POST", "/source_imports_extra", default + 1)
    assert_equal 413, status.call("POST", "/translation_workspace_draft", default + 1)
    assert_equal 413, status.call("POST", "/final_translations/7/refine", default + 1)
    assert_equal 413, status.call("POST", "/glossaries/3/deactivate", default + 1)
  end

  test "undeclared bodies on ordinary routes stop at the default limit while they are read" do
    read_bytes = nil
    middleware = RequestBodyLimit.new(lambda { |environment|
      read_bytes = environment.fetch("rack.input").read.bytesize
      [ 204, {}, [] ]
    })
    environment = ->(input) { { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/projects", "rack.input" => StringIO.new(input) } }

    assert_equal 413, middleware.call(environment.call("a" * (RequestBodyLimit::DEFAULT_MAX_BYTES + 1))).first
    assert_nil read_bytes
    assert_equal 204, middleware.call(environment.call("a" * RequestBodyLimit::DEFAULT_MAX_BYTES)).first
    assert_equal RequestBodyLimit::DEFAULT_MAX_BYTES, read_bytes
  end

  test "every explicit large-body pattern matches a routed form submission" do
    routes = Rails.application.routes.routes.filter_map do |route|
      verb = route.verb.to_s
      next unless RequestBodyLimit::BODY_METHODS.any? { |method| verb.include?(method) }

      route.path.spec.to_s.sub("(.:format)", "").gsub(/:\w+/, "1")
    end

    (RequestBodyLimit::LONG_TEXT_PATHS + RequestBodyLimit::UPLOAD_PATHS).each do |pattern|
      assert routes.any? { |path| pattern.match?(path) }, "#{pattern.inspect} matches no form route"
    end
  end

  test "public form paths, including sign-in, get the small limit however the router spells them" do
    middleware = RequestBodyLimit.new(->(_environment) { [ 204, {}, [] ] })
    oversized = (RequestBodyLimit::PUBLIC_FORM_MAX_BYTES + 1).to_s

    %w[/session /session/ //session /session.html /registration/ //auth//google/callback.html].each do |path|
      assert_equal 413, middleware.call("PATH_INFO" => path, "CONTENT_LENGTH" => oversized).first, path
    end
    assert_equal 204, middleware.call("PATH_INFO" => "/session", "CONTENT_LENGTH" => RequestBodyLimit::PUBLIC_FORM_MAX_BYTES.to_s).first
    assert_equal 204, middleware.call("PATH_INFO" => "/source_imports", "CONTENT_LENGTH" => oversized).first
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

  def upload_environment(extra)
    { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/source_imports" }.merge(extra)
  end

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
