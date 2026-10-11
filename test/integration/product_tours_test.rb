require "test_helper"

class ProductToursTest < ActionDispatch::IntegrationTest
  JSON_HEADERS = { "Accept" => "application/json", "Content-Type" => "application/json" }.freeze

  setup do
    @user = users(:normal)
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    ActionController::Base.cache_store.clear
  end

  test "a new account is offered the tour; an established account is not" do
    sign_in_as @user
    get projects_path
    assert_equal true, tour_props.fetch("offer")

    sign_in_as users(:other)
    get projects_path
    assert_equal false, tour_props.fetch("offer")
  end

  test "the tour props carry labels and element names only, never account data" do
    sign_in_as @user
    get translation_references_path

    props = tour_props
    assert_equal ProductTour::VERSION, props.fetch("version")
    assert_equal product_tour_path, props.dig("urls", "outcome")
    assert_equal ProductTour::GLOBAL_STEPS.size, props.dig("tours", "global").size
    assert_equal ProductTour::PAGE_TOURS.dig("references", :steps).map { |step| step[:id] }, props.dig("tours", "page").map { |step| step["id"] }
    assert_not_includes response.body[/data-react-island="product-tour"[^>]*/], @user.email
    assert_select "script[type='module'][src*='islands']", count: 1
  end

  test "pages without a page tour offer only the full tour" do
    sign_in_as @user
    get settings_account_path
    assert_nil tour_props.dig("tours", "page")
  end

  test "the tour labels follow the account's language" do
    @user.update!(locale: "ja")
    sign_in_as @user
    get projects_path
    assert_equal I18n.t("product_tour.ui.help", locale: :ja), tour_props.dig("messages", "help")
    assert_equal I18n.t("product_tour.global.welcome.title", locale: :ja), tour_props.dig("tours", "global", 0, "title")
  end

  test "completion is recorded once for the signed-in account and repeats change nothing" do
    sign_in_as @user

    patch product_tour_path, params: { product_tour: { outcome: "completed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS
    assert_response :no_content
    assert_equal [ ProductTour::VERSION, "completed" ], [ @user.reload.product_tour_version, @user.product_tour_outcome ]

    patch product_tour_path, params: { product_tour: { outcome: "dismissed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS
    assert_response :no_content
    assert_equal "completed", @user.reload.product_tour_outcome

    get projects_path
    assert_equal false, tour_props.fetch("offer")
  end

  test "malformed, unknown, or outdated outcomes are rejected without a write" do
    sign_in_as @user

    patch product_tour_path, params: { product_tour: { outcome: "preexisting", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS
    assert_response :bad_request
    patch product_tour_path, params: { product_tour: "completed" }.to_json, headers: JSON_HEADERS
    assert_response :bad_request

    patch product_tour_path, params: { product_tour: { outcome: "completed", version: ProductTour::VERSION + 1 } }.to_json, headers: JSON_HEADERS
    assert_response :conflict

    assert_nil @user.reload.product_tour_version
  end

  test "the outcome cannot be written signed out or for another account" do
    patch product_tour_path, params: { product_tour: { outcome: "dismissed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS
    assert_response :redirect
    assert_nil @user.reload.product_tour_version

    other = users(:other)
    other.update_columns(product_tour_version: nil, product_tour_outcome: nil)
    sign_in_as @user
    patch product_tour_path, params: { user_id: other.id, product_tour: { outcome: "dismissed", version: ProductTour::VERSION, user_id: other.id } }.to_json, headers: JSON_HEADERS
    assert_response :no_content
    assert_equal "dismissed", @user.reload.product_tour_outcome
    assert_nil other.reload.product_tour_version
  end

  test "recording the outcome requires a CSRF token when protection is enabled" do
    sign_in_as @user
    ActionController::Base.allow_forgery_protection = true

    patch product_tour_path, params: { product_tour: { outcome: "dismissed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS

    assert_response :unprocessable_content
    assert_nil @user.reload.product_tour_version
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  private

  def tour_props
    island = css_select("[data-react-island='product-tour']").first
    assert island, "the product tour island is rendered"
    JSON.parse(island["data-react-props"])
  end
end
