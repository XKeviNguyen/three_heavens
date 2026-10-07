require "test_helper"

# JSON bodies are parsed into parameters before authentication, so their size
# and structure are bounded before Rails parses them, signed in or not.
class JsonRequestLimitsTest < ActionDispatch::IntegrationTest
  DRAFT_LIMIT = RequestBodyLimit::JSON_PATH_MAX_BYTES.fetch("/translation_workspace_draft")

  # A request body that is generated as it is read and records how much was.
  class GeneratedInput
    attr_reader :bytes_read

    def initialize(total_bytes, unit)
      @total_bytes = total_bytes
      @unit = unit
      @bytes_read = 0
    end

    def read(length = nil, buffer = nil)
      remaining = @total_bytes - @bytes_read
      return (length ? nil : "".b) unless remaining.positive?

      count = [ length || remaining, remaining ].min
      data = (@unit * ((count / @unit.bytesize) + 1)).byteslice(0, count)
      @bytes_read += count
      buffer ? buffer.replace(data) : data
    end

    def rewind = 0
    def gets = read(64 * 1024)
    def each = yield(read(64 * 1024))
  end

  class UnreadableInput
    def read(*) = raise("the body must not be read")
    def rewind = 0
  end

  # Production renders the plain error page; the detailed page would read the
  # unparseable parameters again while describing the error.
  setup { @detailed_exceptions = Rails.application.env_config["action_dispatch.show_detailed_exceptions"] }
  setup { Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false }
  teardown { Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = @detailed_exceptions }

  test "a normal signed-in autosave succeeds" do
    sign_in_as users(:normal)

    post_json translation_workspace_draft_path, draft_body("source_text" => "Hello")

    assert_response :success
  end

  test "the largest legitimate autosave fits the JSON limit" do
    sign_in_as users(:normal)
    body = largest_legitimate_draft_body

    assert_operator body.bytesize, :>, TranslationWorkspaceDraft::MAX_PAYLOAD_BYTES
    assert_operator body.bytesize, :<, DRAFT_LIMIT
    post_json translation_workspace_draft_path, body

    assert_response :success
    assert_equal JSON.parse(body).dig("workspace", "source_text"),
                 users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text")
  end

  test "an autosave of exactly the limit is accepted and one byte more is refused before parsing" do
    sign_in_as users(:normal)
    body = draft_body("source_text" => "At the limit")
    at_limit = body + (" " * (DRAFT_LIMIT - body.bytesize))

    post_json translation_workspace_draft_path, at_limit
    assert_response :success

    post_json translation_workspace_draft_path, at_limit + " "
    assert_response :content_too_large
  end

  test "signed-out JSON is refused by size before authentication and parsed only within the limits" do
    post_json translation_workspace_draft_path, draft_body("source_text" => "Hello")
    assert_redirected_to login_path

    post_json translation_workspace_draft_path, "[" + ("{}," * (DRAFT_LIMIT / 3)) + "{}]"
    assert_response :content_too_large

    post_json session_path, JSON.generate("padding" => "x" * RequestBodyLimit::JSON_MAX_BYTES)
    assert_response :content_too_large
  end

  test "a declared huge JSON body is refused without reading it" do
    status, = Rails.application.call(json_environment("CONTENT_LENGTH" => "3000000000", "rack.input" => UnreadableInput.new))

    assert_equal 413, status
  end

  test "an undeclared streamed JSON body stops at the limit" do
    input = GeneratedInput.new(21 * 1024 * 1024, "{},")
    environment = json_environment("HTTP_TRANSFER_ENCODING" => "chunked", "rack.input" => input)
    environment.delete("CONTENT_LENGTH")

    status, = Rails.application.call(environment)

    assert_equal 413, status
    assert_operator input.bytes_read, :<=, DRAFT_LIMIT + 1
  end

  test "wide, deep, and malformed JSON within the byte limit is refused before allocating it" do
    sign_in_as users(:normal)
    resident_before = resident_megabytes

    [
      "[" + ("{}," * ((DRAFT_LIMIT / 3) - 1)) + "{}]",
      JSON.generate("workspace" => { "model_ids" => Array.new(5_000, "1") }),
      ("[" * 20_000) + ("]" * 20_000),
      ("[" * 200) + ("]" * 200),
      '{"workspace": {"source_text": "unterminated',
      '{"workspace": }'
    ].each do |body|
      post_json translation_workspace_draft_path, body
      assert_response :bad_request, body.first(40)
    end
    assert_empty users(:normal).translation_workspace_drafts
    assert_operator resident_megabytes - resident_before, :<, 32
  end

  test "JSON-typed variants are bounded like application/json" do
    [ "application/json; charset=utf-8", "APPLICATION/JSON", "text/x-json", "application/jsonrequest" ].each do |content_type|
      post translation_workspace_draft_path, params: "[" + ("{}," * (DRAFT_LIMIT / 3)) + "{}]",
                                              headers: { "CONTENT_TYPE" => content_type }
      assert_response :content_too_large, content_type
    end
  end

  test "the token scanner counts structure outside strings only" do
    assert RequestBodyLimit.json_within_token_limit?(JSON.generate("text" => "[{,}]" * 10_000))
    assert RequestBodyLimit.json_within_token_limit?('{"a": "\\"[,{"}')
    assert_not RequestBodyLimit.json_within_token_limit?("[" + ("1," * RequestBodyLimit::JSON_MAX_TOKENS) + "1]")
    assert_not RequestBodyLimit.json_within_token_limit?(("\"\"" * (RequestBodyLimit::JSON_MAX_TOKENS + 1)))
    assert_not RequestBodyLimit.json_within_token_limit?('{"a": "unterminated')
  end

  private

  def post_json(path, body)
    post path, params: body, headers: { "CONTENT_TYPE" => "application/json", "ACCEPT" => "application/json" }
  end

  def json_environment(overrides)
    Rack::MockRequest.env_for(
      "/translation_workspace_draft", method: "POST",
      "CONTENT_TYPE" => "application/json", "HTTP_HOST" => "www.example.com"
    ).merge(overrides)
  end

  # The request the browser sends (workspace_guard_controller.js#persist).
  def draft_body(workspace)
    JSON.generate(project_id: "", draft_id: "", version: "", editor_id: ReplayIdentity.issue(user: users(:normal), context_key: "new"), sequence: 1, workspace:)
  end

  # Every field at its limit, with the source text filled to just under the
  # draft payload limit using characters that JSON encodes in 4 and 6 bytes.
  def largest_legitimate_draft_body
    workspace = {
      "project_name" => "p" * 150, "source_language" => "s" * 100, "target_language" => "t" * 100,
      "document_title" => "d" * 255, "source_import_id" => "1" * 20, "experiment_name" => "e" * 150,
      "instruction_prompt" => "\u0001" * Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS,
      "workflow_mode" => "automatic", "workflow_profile_revision_id" => "2" * 20,
      "glossary_revision_id" => "3" * 20, "methodology_profile_revision_id" => "4" * 20,
      "guidance_preference" => TranslationGuidance::Policy::LABELS.keys.first,
      "model_ids" => Array.new(Ai::UsageLimits::MAX_TRANSLATION_MODELS) { |index| (index + 1).to_s },
      "model_identifiers" => Array.new(Ai::UsageLimits::MAX_TRANSLATION_MODELS) { |index| "provider/model-#{index}" },
      "translation_reference_revision_ids" => Array.new(5) { |index| (index + 10).to_s },
      "source_text" => ""
    }
    characters = Ai::UsageLimits::MAX_SOURCE_CHARACTERS
    workspace["source_text"] = "😀" * characters
    control_characters = (TranslationWorkspaceDraft::MAX_PAYLOAD_BYTES - JSON.generate(workspace).bytesize) / 2
    workspace["source_text"] = ("\u0001" * control_characters) + ("😀" * (characters - control_characters))
    TranslationWorkspaceDraft.validate_payload!(workspace)
    draft_body(workspace)
  end

  def resident_megabytes
    File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/, 1].to_i / 1024
  end
end
