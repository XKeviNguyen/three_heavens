require "test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/workflow_profile_test_helper"

class ProductExperienceTest < ActionDispatch::IntegrationTest
  include MethodologyProfileTestHelper
  include WorkflowProfileTestHelper

  setup do
    sign_in_as users(:normal)
  end

  test "authenticated shell exposes accessible responsive navigation and current page" do
    get new_translation_workspace_path

    assert_response :success
    assert_select "a[href='#main-content']", "Skip to main content"
    assert_select "main#main-content[tabindex='-1']"
    assert_select "nav[aria-label='Primary navigation']"
    assert_select "button[data-action='sidebar#open'][aria-controls='app-sidebar']"
    assert_select "a[aria-current='page']", text: "New translation", minimum: 1

    get projects_path
    assert_select "a[aria-current='page']", text: "Projects", minimum: 1
  end

  test "workspace presents mutually exclusive workflow controls and retry-safe submit state" do
    create_workflow_profile

    get new_translation_workspace_path

    assert_response :success
    assert_select "form[data-controller~='workflow-mode'][data-controller~='workspace-summary']"
    assert_select "fieldset[data-workflow-mode-target='manual'][data-available='true']"
    assert_select "fieldset[data-workflow-mode-target='automatic'][data-available='true']"
    assert_select "input[type='submit'][data-workflow-mode-target='submit'][data-turbo-submits-with='Starting translation…']:not([disabled])"
    assert_select "input[name='translation_workspace[workflow_mode]'][data-action='workflow-mode#update']", count: 2
  end

  test "workflow pages expose a linked stage trail with a current step" do
    experiment = experiments(:one)
    experiment.update!(status: :completed)

    get experiment_path(experiment)

    assert_response :success
    assert_select "nav[aria-label='Translation workflow']" do
      assert_select "li", count: 4
      assert_select "a[href='#{experiment_path(experiment)}']", text: /Translation.*Complete/m
      assert_select "div", text: /Blind review.*Waiting/m
    end
  end

  test "methodology indexes and immutable revision histories stay bounded and clamp pages" do
    27.times { |index| create_methodology_profile(name: "Bounded methodology #{index}") }

    get methodology_profiles_path
    assert_response :success
    assert_select "section[aria-label='Methodologies'] article", count: 25
    assert_select "nav[aria-label='Methodologies pagination']", text: /Page 1 of 2.*27 items/m

    get methodology_profiles_path(page: 999)
    assert_response :success
    assert_select "section[aria-label='Methodologies'] article", count: 2
    assert_select "nav[aria-label='Methodologies pagination']", text: /Page 2 of 2/

    # Counts come from the locale, not from English pluralization of the label.
    { "vi" => "27 mục", "ja" => "27件" }.each do |locale, count|
      users(:normal).update!(locale: locale)
      get methodology_profiles_path
      assert_select "nav p", text: /#{count}\z/
      assert_no_match(/27 \S+s\b/, css_select("nav p").map(&:text).join(" "))
    end
    users(:normal).update!(locale: "en")

    profile = MethodologyProfile.order(:id).last
    26.times do |index|
      MethodologyProfiles::Revise.call(
        methodology_profile: profile,
        expected_version: profile.reload.current_revision.version,
        attributes: methodology_profile_attributes(name: "Revision #{index}")
      )
    end
    get methodology_profile_path(profile)
    assert_response :success
    assert_select "section", text: /Version 27 · Current/, minimum: 1
    assert_select "nav[aria-label='Versions pagination']", text: /Page 1 of 2.*27 items/m
  end

  test "non-owned records render a generic private-safe not-found page" do
    get project_path(projects(:two))

    assert_response :not_found
    assert_select "h1", "We couldn’t find that page"
    assert_not_includes response.body, projects(:two).description
    assert_not_includes response.body, "Couldn't find Project"
  end
end
