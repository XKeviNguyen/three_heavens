require "test_helper"
require_relative "../support/upload_budget_clock"

class UploadAttemptAdmissionTest < ActionDispatch::IntegrationTest
  include UploadBudgetClock

  class ObservedInput < StringIO
    attr_reader :bytes_read

    def initialize(body)
      super(body)
      @bytes_read = 0
    end

    def read(*)
      super.tap { |bytes| @bytes_read += bytes.to_s.bytesize }
    end
  end

  test "malformed deliveries with the same key exhaust attempt admission before Rack reads another body" do
    sign_in_as users(:normal)
    key = ReplayIdentity.issue
    30.times do
      status, input = deliver(key:)
      assert_equal 422, status
      assert_operator input.bytes_read, :>, 0
    end
    status, input, headers = deliver(key:)
    assert_equal 429, status
    assert_equal 0, input.bytes_read
    assert_equal "300", headers["retry-after"]
    assert_equal 0, users(:normal).source_imports.count
    assert_equal 0, UploadBudget.find_by(user: users(:normal))&.count.to_i
  end

  test "signed out upload is refused without parsing its bounded multipart body" do
    status, input = deliver
    assert_equal 401, status
    assert_equal 0, input.bytes_read
  end

  test "normalized source and reference upload routes reject before parsing including method override bodies" do
    %w[//source_imports/ /source_imports.json /source_imports.html/ /translation_references /translation_references/9.json].each do |path|
      %w[POST PATCH PUT].each do |method|
        status, input = deliver(path:, method:)
        assert_equal 401, status, "#{method} #{path}"
        assert_equal 0, input.bytes_read
      end
    end
  end

  test "all Rack multipart variants are admitted before reference body parsing" do
    variants = [ "multipart/mixed; boundary=BOUNDARY", "multipart/related; boundary=BOUNDARY",
      "multipart/form-data, boundary=BOUNDARY", "multipart/form-data; boundary=BOUNDARY" ]
    variants.each do |content_type|
      status, input = deliver(path: "/translation_references", content_type:)
      assert_equal 401, status, content_type
      assert_equal 0, input.bytes_read
    end
    sign_in_as users(:normal)
    30.times { assert UploadBudget.admit_attempt(user: users(:normal)) }
    variants.each do |content_type|
      status, input = deliver(path: "/translation_references", content_type:)
      assert_equal 429, status, content_type
      assert_equal 0, input.bytes_read
    end
  end

  test "expired revoked disabled and unverified sessions cannot pay for body parsing" do
    user = users(:normal)
    sign_in_as user
    original_cookie = cookies["_three_heavens_session"]
    session_row = Session.find_by!(id: session[:authentication_session_id])
    session_row.update!(created_at: (Session::LIFETIME + 1.day).ago)
    assert_unread_denial(original_cookie)
    session_row.update!(created_at: Time.current)
    user.update!(email_verified_at: nil)
    assert_unread_denial(original_cookie)
    user.update!(email_verified_at: Time.current, status: :disabled)
    assert_unread_denial(original_cookie)
    user.update!(status: :active)
    assert_unread_denial(original_cookie)
    assert_unread_denial("invalid-cookie")
    assert_nil UploadBudget.find_by(user:)
  end

  test "exact replay remains usable when extraction work is exhausted" do
    user = users(:normal)
    sign_in_as user
    key = ReplayIdentity.issue
    status, _, _, body = deliver(key:, filename: "source.txt")
    assert_equal 201, status
    id = JSON.parse(body).fetch("id")
    9.times { assert UploadBudget.consume(user:) }
    assert_no_difference [ -> { SourceImport.count }, -> { ActiveStorage::Blob.count } ] do
      status, _, _, body = deliver(key:, filename: "source.txt")
      assert_equal 201, status
      assert_equal id, JSON.parse(body).fetch("id")
    end
    status, = deliver(filename: "source.txt")
    assert_equal 429, status
    assert_equal 10, UploadBudget.find_by!(user:).count
    assert_equal 3, UploadBudget.find_by!(user:).attempt_count
  end

  test "authenticated undeclared upload bodies still enforce the streaming size limit" do
    sign_in_as users(:normal)
    status, input = deliver(contents: "x" * RequestBodyLimit::MAX_BYTES, declared: false)
    assert_equal 413, status
    assert_operator input.bytes_read, :<=, RequestBodyLimit::MAX_BYTES + RequestBodyLimit::LimitedInput::READ_CHUNK_BYTES
  end

  private

  def assert_unread_denial(cookie)
    status, input = deliver(cookie:)
    assert_equal 401, status
    assert_equal 0, input.bytes_read
  end

  def deliver(key: ReplayIdentity.issue, path: "/source_imports", cookie: cookies["_three_heavens_session"],
    method: "POST", filename: "mismatch.pdf", contents: "This is bounded plain text, not a PDF.", declared: true, content_type: nil)
    boundary = "review79-safe-boundary"
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"source_import[request_key]\"\r\n\r\n#{key}\r\n" \
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"source_import[source_file]\"; filename=\"#{filename}\"\r\n" \
      "Content-Type: #{filename.end_with?('.pdf') ? 'application/pdf' : 'text/plain'}\r\n\r\n#{contents}\r\n--#{boundary}--\r\n"
    input = ObservedInput.new(body)
    environment = Rack::MockRequest.env_for(path, method:, "CONTENT_TYPE" => (content_type&.sub("BOUNDARY", boundary) || "multipart/form-data; boundary=#{boundary}"),
      "CONTENT_LENGTH" => body.bytesize.to_s, "HTTP_ACCEPT" => "application/json",
      "HTTP_COOKIE" => ("_three_heavens_session=#{Rack::Utils.escape(cookie)}" if cookie))
    environment["rack.input"] = input
    environment["PATH_INFO"] = path
    environment.delete("CONTENT_LENGTH") unless declared
    status, headers, response_body = Rails.application.call(environment)
    rendered = +""
    response_body.each { |part| rendered << part }
    response_body.close if response_body.respond_to?(:close)
    [ status, input, headers, rendered ]
  end
end
