require "test_helper"

class AdminAuthorizationTest < ActionDispatch::IntegrationTest
  test "admin may manage the model catalog" do
    sign_in_as users(:admin)

    get settings_models_path

    assert_response :success
    assert_select "h1", "OpenRouter model catalog"
    assert_select "a[href='#{settings_models_path}']", "Settings / Models"
  end

  test "normal user is denied server-side and does not see the navigation link" do
    sign_in_as users(:normal)
    model = llm_models(:openrouter_claude)
    original_name = model.display_name

    get root_path
    assert_select "a[href='#{settings_models_path}']", count: 0

    get settings_models_path
    assert_redirected_to root_path
    follow_redirect!
    assert_select "[role='alert']", text: /not authorized/

    patch settings_model_path(model), params: {
      llm_model: {
        provider: model.provider,
        model_identifier: model.model_identifier,
        display_name: "Unauthorized change"
      }
    }
    assert_redirected_to root_path
    assert_equal original_name, model.reload.display_name
  end

  test "unauthenticated user is sent to login before model authorization" do
    get settings_models_path

    assert_redirected_to login_path
  end
end
