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
    assert_response :ok
    assert_equal true, response.parsed_body.fetch("page_guides")
    assert_equal [ ProductTour::VERSION, "completed" ], [ @user.reload.product_tour_version, @user.product_tour_outcome ]

    patch product_tour_path, params: { product_tour: { outcome: "dismissed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS
    assert_response :ok
    assert_equal true, response.parsed_body.fetch("page_guides")
    assert_equal "completed", @user.reload.product_tour_outcome

    get projects_path
    assert_equal false, tour_props.fetch("offer")
  end

  test "a completion arriving after another tab dismissed the offer reports page guides off" do
    sign_in_as @user
    patch product_tour_path, params: { product_tour: { outcome: "dismissed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS
    patch product_tour_path, params: { product_tour: { outcome: "completed", version: ProductTour::VERSION } }.to_json, headers: JSON_HEADERS

    assert_response :ok
    assert_equal false, response.parsed_body.fetch("page_guides")
    assert_equal [ "dismissed", false ], [ @user.reload.product_tour_outcome, @user.product_tour_page_guides ]
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
    assert_response :ok
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

  test "page guide props name this page's context and the account's own progress" do
    sign_in_as @user
    get projects_path
    assert_equal({ "enabled" => false, "revision" => @user.reload.product_tour_guides_revision, "key" => "projects:list",
                   "version" => ProductTour::PAGE_VERSION, "seen" => false }, tour_props.fetch("page_guides"))
    assert_equal page_product_tour_path, tour_props.dig("urls", "page")

    @user.update_columns(product_tour_page_guides: true)
    ProductTour.record_page_outcome!(@user, "projects:list", "completed")
    get projects_path
    assert_equal [ true, true ], tour_props.fetch("page_guides").values_at("enabled", "seen")

    get project_path(projects(:one))
    assert_equal [ "projects:detail", false ], tour_props.fetch("page_guides").values_at("key", "seen")
    get settings_account_path
    assert_nil tour_props.dig("page_guides", "key"), "pages without a guide have no key"

    # Only the rewritten guide moved to a newer version.
    get new_translation_workspace_path
    assert_equal [ "translation_workspaces:form", 2, false ], tour_props.fetch("page_guides").values_at("key", "version", "seen")
    assert_equal %w[intro languages source terminology references methodology priority workflow launch], tour_props.dig("tours", "page").pluck("id")
  end

  test "a page guide's outcome is recorded once for the signed-in account" do
    sign_in_as @user
    body = { product_tour_page: { key: "glossaries:list", outcome: "completed", version: ProductTour::PAGE_VERSION } }
    patch page_product_tour_path, params: body.to_json, headers: JSON_HEADERS
    assert_response :ok
    assert_equal({ "recorded" => true }, response.parsed_body)
    patch page_product_tour_path, params: body.deep_merge(product_tour_page: { outcome: "dismissed" }).to_json, headers: JSON_HEADERS
    assert_equal({ "recorded" => false }, response.parsed_body, "a second tab's claim loses")

    assert_equal [ [ "glossaries:list", "completed" ] ], @user.product_tour_page_outcomes.pluck(:tour_key, :outcome)
  end

  test "unknown, malformed, or outdated page guide writes are rejected without a write" do
    sign_in_as @user
    [
      [ { key: "admin_users:list", outcome: "completed", version: 1 }, :bad_request ],
      [ { key: "projects:list:extra", outcome: "completed", version: 1 }, :bad_request ],
      [ { key: "projects:list:", outcome: "completed", version: 1 }, :bad_request ],
      [ { key: "projects:list\n", outcome: "completed", version: 1 }, :bad_request ],
      [ { key: "projects:edit", outcome: "completed", version: 1 }, :bad_request ],
      [ { key: "projects:list", outcome: "preexisting", version: 1 }, :bad_request ],
      [ { key: "projects:list", outcome: "completed", version: ProductTour::PAGE_VERSION + 1 }, :conflict ],
      # New translation's guide was rewritten: a page still showing the old one cannot record it.
      [ { key: "translation_workspaces:form", outcome: "completed", version: 1 }, :conflict ]
    ].each do |attributes, status|
      patch page_product_tour_path, params: { product_tour_page: attributes }.to_json, headers: JSON_HEADERS
      assert_response status, attributes.inspect
    end
    assert_empty ProductTourPageOutcome.all
  end

  test "page guide progress and the guides switch belong to the signed-in account only" do
    patch page_product_tour_path, params: { product_tour_page: { key: "projects:list", outcome: "completed", version: 1 } }.to_json, headers: JSON_HEADERS
    assert_response :redirect
    patch preference_product_tour_path, params: { product_tour_preference: { page_guides: true } }.to_json, headers: JSON_HEADERS
    assert_response :redirect

    other = users(:other)
    sign_in_as @user
    patch page_product_tour_path, params: { user_id: other.id, product_tour_page: { key: "projects:list", outcome: "completed", version: 1, user_id: other.id } }.to_json, headers: JSON_HEADERS
    patch preference_product_tour_path, params: { user_id: other.id, product_tour_preference: { page_guides: true, user_id: other.id } }.to_json, headers: JSON_HEADERS
    assert_equal [ 1, true ], [ @user.product_tour_page_outcomes.count, @user.reload.product_tour_page_guides ]
    assert_equal [ 0, false ], [ other.product_tour_page_outcomes.count, other.reload.product_tour_page_guides ]
  end

  test "the guides switch accepts only true or false" do
    sign_in_as @user
    get projects_path
    rendered_revision = tour_props.dig("page_guides", "revision")
    patch preference_product_tour_path, params: { product_tour_preference: { page_guides: true } }.to_json, headers: JSON_HEADERS
    assert_response :ok
    assert @user.reload.product_tour_page_guides
    # The answer orders the switch after any page rendered before it.
    assert_equal({ "page_guides" => true, "revision" => @user.product_tour_guides_revision }, response.parsed_body)
    assert_operator response.parsed_body["revision"], :>, rendered_revision
    patch preference_product_tour_path, params: { product_tour_preference: { page_guides: "false" } }.to_json, headers: JSON_HEADERS
    assert_response :bad_request
    assert @user.reload.product_tour_page_guides
    patch preference_product_tour_path, params: { product_tour_preference: { page_guides: false } }.to_json, headers: JSON_HEADERS
    assert_not @user.reload.product_tour_page_guides
  end

  test "page guide writes require a CSRF token when protection is enabled" do
    sign_in_as @user
    ActionController::Base.allow_forgery_protection = true
    patch page_product_tour_path, params: { product_tour_page: { key: "projects:list", outcome: "completed", version: 1 } }.to_json, headers: JSON_HEADERS
    assert_response :unprocessable_content
    patch preference_product_tour_path, params: { product_tour_preference: { page_guides: true } }.to_json, headers: JSON_HEADERS
    assert_response :unprocessable_content
    assert_equal [ 0, false ], [ @user.product_tour_page_outcomes.count, @user.reload.product_tour_page_guides ]
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
