require "application_system_test_case"

class LanguageComboboxTest < ApplicationSystemTestCase
  setup do
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  test "uncommitted search text restores the known or blank committed value" do
    visit new_translation_workspace_path

    choose_known_language "Source language", "Japanese"
    source = find_field("Source language")
    source.fill_in with: "abcxyz"
    find_field("Project name").click
    assert_field "Source language", with: "Japanese"
    assert_equal "Japanese", committed_value("translation_workspace[source_language]")

    target = find_field("Target language")
    target.fill_in with: "abcxyz"
    target.send_keys(:tab)
    assert_field "Target language", with: ""
    assert_equal "", committed_value("translation_workspace[target_language]")
  end

  test "custom language requires explicit localized activation" do
    visit new_translation_workspace_path
    source = find_field("Source language")
    source.fill_in with: "Church Japanese"

    find("[data-combobox-target='custom']", text: "Use “Church Japanese” as a custom language").click
    assert_field "Source language", with: "Church Japanese"
    assert_equal "Church Japanese", committed_value("translation_workspace[source_language]")
    assert_selector "[data-combobox-target='status']", text: "Custom language"
  end

  test "Vietnamese search ignores Latin diacritics and Japanese native search remains available" do
    visit new_translation_workspace_path
    switch_locale("Tiếng Việt")

    source = find_field("Ngôn ngữ nguồn")
    source.fill_in with: "nhat"
    assert_selector "[role='option']", text: /Tiếng Nhật.*日本語/
    source.fill_in with: "tieng viet"
    assert_selector "[role='option']", text: /Tiếng Việt/
    source.fill_in with: "日本"
    assert_selector "[role='option']", text: /Tiếng Nhật.*日本語/

    source.fill_in with: "nhat"
    source.send_keys(:arrow_down, :enter)
    assert_equal "Japanese", committed_value("translation_workspace[source_language]")
    assert_field "Ngôn ngữ nguồn", with: "Japanese"

    switch_locale("日本語", current_label: "Ngôn ngữ giao diện")
    assert_selector "html[lang='ja']"
    assert_equal "Japanese", committed_value("translation_workspace[source_language]")
    assert_field "原文の言語", with: "Japanese"

    find_field("訳文の言語").fill_in with: "教会日本語"
    assert_selector "[data-combobox-target='custom']", text: "「教会日本語」をカスタム言語として使用"
  end

  test "shared language pickers restore committed values on every form surface" do
    surfaces = [
      [ new_translation_workspace_path, "translation_workspace[source_language]", "Project name" ],
      [ new_glossary_path, "glossary[source_language]", "Name" ],
      [ new_translation_reference_path, "translation_reference[source_language]", "Title" ],
      [ new_methodology_profile_path, "methodology_profile[source_language]", "Name" ]
    ]

    surfaces.each do |path, hidden_name, outside_label|
      visit path
      choose_known_language "Source language", "Japanese"
      find_field("Source language").fill_in with: "not selected"
      find_field(outside_label).click
      assert_field "Source language", with: "Japanese"
      assert_equal "Japanese", committed_value(hidden_name)
    end
  end

  private

  def committed_value(name)
    find("input[name='#{name}']", visible: :all).value
  end

  def switch_locale(option, current_label: "Interface language")
    within "aside#app-sidebar" do
      select option, from: current_label
    end
  end
end
