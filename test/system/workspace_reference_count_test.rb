require "application_system_test_case"
require_relative "../support/translation_reference_test_helper"

class WorkspaceReferenceCountTest < ApplicationSystemTestCase
  include TranslationReferenceTestHelper

  # The count was rendered once by the server, so checking boxes (or the
  # browser restoring checked boxes on reload) left it at "0 of 5".
  test "the selected-references count follows the checkboxes" do
    first = create_translation_reference(title: "Easter sermon", source_language: "Vietnamese", target_language: "Japanese")
    second = create_translation_reference(title: "Christmas sermon", source_language: "Vietnamese", target_language: "Japanese")

    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
    visit new_translation_workspace_path

    within("#workspace-references") do
      assert_text "0 of 5 references selected"
      find("#translation_workspace_translation_reference_revision_ids_#{first.current_revision.id}").check
      assert_text "1 of 5 references selected"
      find("#translation_workspace_translation_reference_revision_ids_#{second.current_revision.id}").check
      assert_text "2 of 5 references selected"
      find("#translation_workspace_translation_reference_revision_ids_#{first.current_revision.id}").uncheck
      assert_text "1 of 5 references selected"
    end
  end
end
