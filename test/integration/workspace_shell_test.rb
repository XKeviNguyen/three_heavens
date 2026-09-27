require "test_helper"

class WorkspaceShellTest < ActionDispatch::IntegrationTest
  test "authenticated shell renders grouped sidebar navigation with brand and language picker" do
    sign_in_as users(:normal)

    get new_translation_workspace_path

    assert_response :success
    assert_select "aside[aria-label='Primary navigation']" do
      assert_select "span", text: "Three Heavens"
      assert_select "p", text: "Work"
      assert_select "p", text: "Library"
      assert_select "p", text: "Insights"
      assert_select "p", text: "Admin", count: 0
      assert_select "a", text: "New translation"
      assert_select "a", text: "Projects"
      assert_select "a", text: "History"
      assert_select "a", text: "Terminology"
      assert_select "a", text: "References"
      assert_select "a", text: "Methodology"
      assert_select "a", text: "Workflows"
      assert_select "a", text: "Benchmarks"
    end

    assert_select "li[role='option'][data-value='Vietnamese']"
    assert_select "li[role='option'][data-value='Japanese']"
    assert_select "input[type='text'][role='combobox'][id='translation_workspace_source_language']"

    assert_select "span[role='tooltip']", minimum: 1
    assert_select "button[aria-describedby][aria-label^='More information about']", minimum: 1
  end

  test "admin shell exposes Models and Operations only to admins" do
    sign_in_as users(:admin)

    get new_translation_workspace_path

    assert_response :success
    assert_select "aside[aria-label='Primary navigation']" do
      assert_select "p", text: "Admin"
      assert_select "a", text: "Models"
      assert_select "a", text: "Operations"
    end
  end

  test "unauthenticated shell keeps the brand visible on the login page" do
    get login_path

    assert_response :success
    assert_select "a", text: "Three Heavens"
    assert_select "a", text: "New translation", count: 0
  end

  test "existing project workspace shows the authoritative language pair" do
    user = users(:normal)
    sign_in_as user
    project = user.projects.create!(name: "Fixed pair", source_language: "Klingon", target_language: "Japanese")

    get new_translation_workspace_path(project_id: project.id)

    assert_response :success
    assert_select "h1", "Add a translation to this Project"
    assert_select "#workspace-source-languages", text: /Klingon.*Japanese/
    assert_select "input[name='translation_workspace[source_language]']", count: 0
  end
end
