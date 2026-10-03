require "test_helper"

# Client input never becomes a server error. Each signed-out identity endpoint
# receives malformed shapes and values; a NUL byte, which PostgreSQL text
# cannot hold, is refused as a bad request wherever it appears.
class MalformedInputTest < ActionDispatch::IntegrationTest
  VALUES = {
    nul: "user\0@example.test",
    long: "x" * 6_000,
    array: [ "a", "b" ],
    hash: { "a" => "b" },
    nested_hash: { "a" => { "b" => "c" } },
    empty: "",
    invalid_utf8: "\xFF\xFE".b
  }.freeze

  PUBLIC_ENDPOINTS = {
    "sign-in fields" => [ :post, "/session", ->(value) { { session: { email: value, password: value } } } ],
    "sign-in object" => [ :post, "/session", ->(value) { { session: value } } ],
    "registration fields" => [ :post, "/registration", ->(value) { { user: { email: value, password: value, password_confirmation: value } } } ],
    "registration object" => [ :post, "/registration", ->(value) { { user: value } } ],
    "registration password" => [ :post, "/registration", ->(value) { { user: { email: "new.person@example.test", password: value, password_confirmation: value } } } ],
    "confirmation resend" => [ :post, "/confirmation_resend", ->(value) { { email: value } } ],
    "confirmation page" => [ :get, "/email_confirmation", ->(value) { { token: value } } ],
    "confirmation" => [ :post, "/email_confirmation", ->(value) { { token: value } } ],
    "Google ceremony" => [ :post, "/auth/google/ceremony", ->(value) { { intent: value } } ],
    "Google callback" => [ :post, "/auth/google/callback", ->(value) { { credential: value, g_csrf_token: value } } ],
    "Google completion" => [ :get, "/auth/google/complete", ->(value) { { extra: value } } ],
    "locale" => [ :patch, "/locale", ->(value) { { locale_code: value, return_to: value } } ],
    "appearance" => [ :patch, "/appearance", ->(value) { { appearance: value, return_to: value } } ]
  }.freeze

  PUBLIC_ENDPOINTS.each.with_index do |(label, (verb, path, build)), endpoint_index|
    VALUES.each.with_index do |(value_label, value), value_index|
      test "#{label} answers #{value_label} input without a server error" do
        cookies["g_csrf_token"] = "token"
        assert_no_difference -> { User.count } do
          send(verb, path, params: build.call(value), headers: { "REMOTE_ADDR" => "192.0.2.#{(endpoint_index * VALUES.size) + value_index + 1}" })
        end

        assert_operator response.status, :<, 500
        assert_response :bad_request if value_label == :nul
      end
    end
  end

  test "unexpected content types and attributes on signed-out endpoints are client errors" do
    json = '{"session":{"email":["a"],"admin":true},"user":{"email":{"a":1},"role":"admin"},"email":[1],"token":{"a":1}}'
    [ [ "application/json", json ], [ "text/plain", "garbage\0data" ], [ "application/xml", "<a/>" ],
      [ "multipart/form-data; boundary=x", "garbage" ] ].each.with_index do |(type, body), type_index|
      %w[/session /registration /confirmation_resend /email_confirmation /auth/google/callback /auth/google/ceremony /locale /appearance].each.with_index do |path, path_index|
        post path, params: body, headers: { "CONTENT_TYPE" => type, "REMOTE_ADDR" => "198.51.100.#{(type_index * 10) + path_index + 1}" }

        assert_operator response.status, :<, 500, "#{type} #{path}"
      end
    end
    assert_equal 0, User.where(role: :admin).where.not(id: users(:admin).id).count
  end

  test "a NUL byte in a signed-in form is refused before it reaches a query" do
    sign_in_as users(:normal)
    glossary = { name: "Glossary\0", description: "", source_language: "Vietnamese", target_language: "Japanese",
                 entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "" } ] }
    workspace = { project_name: "Project", source_language: "Vietnamese", target_language: "Japanese",
                  document_title: "Source", source_text: "Source\0text", experiment_name: "Experiment",
                  instruction_prompt: "Translate.", workflow_mode: "manual",
                  model_ids: [ llm_models(:openrouter_claude).id.to_s ], submission_token: issue_translation_workspace_token }

    assert_no_difference [ "Glossary.count", "Project.count", "Experiment.count" ] do
      post glossaries_path, params: { glossary: }
      assert_response :bad_request
      post translation_workspace_path, params: { translation_workspace: workspace }
      assert_response :bad_request
      get history_path, params: { "q\0" => "x" }
      assert_response :bad_request
    end
  end
end
