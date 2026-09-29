require "test_helper"

class LocalizedApplicationPagesTest < ActionDispatch::IntegrationTest
  test "normal application pages render in every supported locale" do
    user = users(:normal)
    sign_in_as user

    %w[en vi ja].each do |locale|
      user.update!(locale: locale)
      [
        new_translation_workspace_path,
        projects_path,
        project_path(projects(:one)),
        history_path,
        glossaries_path,
        translation_references_path,
        methodology_profiles_path,
        workflow_profiles_path,
        benchmarks_path,
        benchmark_model_path(llm_models(:openrouter_claude)),
        experiment_path(experiments(:one))
      ].each do |path|
        get path
        assert_response :success, "#{locale} #{path}"
        assert_select "html[lang='#{locale}']", 1, "#{locale} #{path}"
        assert_no_match(/Translation missing|translation missing|%= /, response.body, "#{locale} #{path}")
      end
    end
  end


  %w[en vi ja].each do |locale|
    test "operations page renders in #{locale}" do
      admin = users(:admin)
      admin.update!(locale: locale)
      sign_in_as admin

      get settings_operations_path
      assert_response :success
      assert_select "html[lang='#{locale}']", 1
      assert_no_match(/Translation missing|translation missing|%= /, response.body)
    end
  end

  test "public pages render in every supported locale" do
    %w[en vi ja].each do |locale|
      patch locale_path, params: { locale_code: locale }
      [ root_path, new_registration_path, login_path ].each do |path|
        get path
        assert_response :success, "#{locale} #{path}"
        assert_select "html[lang='#{locale}']", 1, "#{locale} #{path}"
        assert_no_match(/Translation missing|translation missing|%= /, response.body, "#{locale} #{path}")
      end
    end
  end

  test "admin and not-found pages render in every supported locale" do
    admin = users(:admin)
    sign_in_as admin

    %w[en vi ja].each do |locale|
      admin.update!(locale: locale)
      [ settings_users_path, settings_models_path ].each do |path|
        get path
        assert_response :success, "#{locale} #{path}"
        assert_select "html[lang='#{locale}']", 1, "#{locale} #{path}"
        assert_no_match(/Translation missing|translation missing|%= /, response.body, "#{locale} #{path}")
      end
      get project_path(projects(:two))
      assert_response :not_found
      assert_select "html[lang='#{locale}']", 1
      assert_no_match(/Translation missing|translation missing|%= /, response.body)
    end
  end
end
