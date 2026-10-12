require "application_system_test_case"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/translation_reference_test_helper"

# New translation shows every kind of translation guidance at once: they used
# to sit behind a small disclosure that few people opened.
class TranslationGuidanceTest < ApplicationSystemTestCase
  include MethodologyProfileTestHelper
  include TranslationReferenceTestHelper

  SECTIONS = %w[#workspace-glossary #workspace-references #workspace-methodology #workspace-guidance].freeze

  setup do
    @user = users(:normal)
    @reference = create_translation_reference(title: "Approved sermon")
    @methodology = create_methodology_profile(name: "Literary register")
    visit login_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  test "terminology, references, methodology and priority are all shown, in order, without opening anything" do
    visit new_translation_workspace_path
    assert_no_selector "details > summary", text: /references|methodology/i
    titles = SECTIONS.map do |section|
      within(section) { find("legend", visible: true).text }
    end
    assert_equal [ "1Terminology", "2Translation references", "3Methodology", "4Guidance priority" ], titles.map { |title| title.delete("\n") }
    assert_text "Select preferred terms to keep translations consistent."
    assert_text "Choose which guidance takes priority when they conflict."

    # Desktop: terminology spans the row; references sit beside methodology.
    boxes = SECTIONS.to_h { |section| [ section, find("#{section} > legend").rect ] }
    assert_operator boxes["#workspace-references"].y, :>, boxes["#workspace-glossary"].y
    assert_in_delta boxes["#workspace-references"].y, boxes["#workspace-methodology"].y, 2
    assert_operator boxes["#workspace-methodology"].x, :>, boxes["#workspace-references"].x
    assert_operator boxes["#workspace-guidance"].y, :>, boxes["#workspace-methodology"].y
  end

  test "the choices work by keyboard and come back from the saved draft" do
    visit new_translation_workspace_path
    choose_known_language("Source language", "Vietnamese")
    choose_known_language("Target language", "Japanese")

    reference = find("#workspace-references input[type=checkbox][value='#{@reference.current_revision_id}']")
    reference.send_keys(:space)
    assert reference.checked?
    methodology = find("#workspace-methodology input[type=radio][value='#{@methodology.current_revision_id}']")
    methodology.send_keys(:space)
    assert methodology.checked?
    priority = find("#workspace-guidance input[type=radio][value='glossary']")
    priority.send_keys(:space)
    assert priority.checked?
    assert_until do
      payload = @user.translation_workspace_drafts.find_by(context_key: TranslationWorkspaceDraft.context_key(nil))&.payload || {}
      payload["methodology_profile_revision_id"] == @methodology.current_revision_id.to_s && payload["guidance_preference"] == "glossary"
    end

    visit new_translation_workspace_path
    assert_checked_field "translation_workspace[translation_reference_revision_ids][]", with: @reference.current_revision_id.to_s
    assert_checked_field "translation_workspace[methodology_profile_revision_id]", with: @methodology.current_revision_id.to_s
    assert_checked_field "translation_workspace[guidance_preference]", with: "glossary"
  end

  test "on a phone in Vietnamese and Japanese the four sections stack in one column with nothing cut off" do
    page.current_window.resize_to(390, 844)
    { "vi" => "Bản dịch tham khảo", "ja" => "参考訳" }.each do |locale, references|
      @user.update_columns(locale: locale)
      visit new_translation_workspace_path
      within("#workspace-references") { assert_selector "legend", text: references }
      lefts = SECTIONS.map { |section| find(section).rect.x.round }
      assert_equal 1, lefts.uniq.size, "#{locale}: one column"
      tops = SECTIONS.map { |section| find(section).rect.y }
      assert_equal tops.sort, tops, "#{locale}: in reading order"
      overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
      assert_equal 0, overflow, "#{locale}: no sideways scrolling"
    end
  ensure
    page.current_window.resize_to(1400, 1000)
  end

  private

  def assert_until(timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
  end
end
