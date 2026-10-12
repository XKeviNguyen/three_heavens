require "test_helper"

class ProductTourTest < ActiveSupport::TestCase
  setup do
    @user = users(:normal)
    @user.update_columns(product_tour_version: nil, product_tour_outcome: nil)
  end

  test "an account that never resolved the current version is offered the tour" do
    assert ProductTour.offered?(@user)

    @user.update_columns(product_tour_version: ProductTour::VERSION, product_tour_outcome: "dismissed")
    assert_not ProductTour.offered?(@user)

    @user.update_columns(product_tour_version: ProductTour::VERSION - 1) if ProductTour::VERSION > 1
    assert_equal ProductTour::VERSION > 1, ProductTour.offered?(@user)
  end

  test "the first resolution wins and repeats write nothing" do
    assert ProductTour.record_outcome!(@user, "completed")

    assert_no_changes -> { @user.reload.attributes.slice("product_tour_version", "product_tour_outcome", "updated_at") } do
      assert_not ProductTour.record_outcome!(@user, "dismissed")
      assert_not ProductTour.record_outcome!(@user, "completed")
    end
    assert_equal [ ProductTour::VERSION, "completed" ], [ @user.product_tour_version, @user.product_tour_outcome ]
  end

  test "an established account is never rewritten by an outcome" do
    preexisting = users(:other)

    assert_not ProductTour.record_outcome!(preexisting, "completed")
    assert_equal "preexisting", preexisting.reload.product_tour_outcome
  end

  test "only known outcomes are recorded and the database rejects inconsistent state" do
    assert_raises(ArgumentError) { ProductTour.record_outcome!(@user, "preexisting") }
    assert_raises(ActiveRecord::StatementInvalid) { @user.update_columns(product_tour_version: 1, product_tour_outcome: nil) }
  end

  test "a page view maps to one guide context; other requests and pages to none" do
    assert_equal "projects:list", ProductTour.page_context_key("projects", "index", "GET")
    assert_equal "projects:detail", ProductTour.page_context_key("projects", "show", "GET")
    assert_equal "translation_references:form", ProductTour.page_context_key("translation_references", "new", "GET")
    assert_equal "settings_ai_settings:detail", ProductTour.page_context_key("settings/ai_settings", "show", "GET")
    assert_nil ProductTour.page_context_key("translation_references", "create", "POST"), "a re-rendered form is mid-task"
    assert_nil ProductTour.page_context_key("settings/accounts", "show", "GET")
    assert_nil ProductTour.page_context_key("projects", "download", "GET")

    assert ProductTour.valid_page_key?("glossaries:form")
    [ "glossaries", "terminology:list", "admin:list", "glossaries:list:x", "glossaries:list:", "glossaries:list\n", "glossaries:edit" ].each { |key| assert_not ProductTour.valid_page_key?(key), key }
  end

  test "every guided page has its own key, so pages of one family are taught separately" do
    keys = ProductTour::PAGE_TOUR_BY_CONTROLLER.keys.flat_map do |controller|
      %w[index new show].filter_map { |action| ProductTour.page_context_key(controller, action, "GET") }
    end
    assert_equal keys.uniq, keys
    keys.each { |key| assert(ProductTour.valid_page_key?(key) && key.length <= 64, key) }
    # Both belong to the workflows family but show different steps.
    assert_not_equal ProductTour.page_context_key("workflow_profiles", "show", "GET"),
                     ProductTour.page_context_key("pipeline_runs", "show", "GET")
  end

  test "the switch's revision follows the order writes commit in, not the clock" do
    before = ProductTour.page_guides_state(@user)
    travel_to(Time.current) { ProductTour.set_page_guides!(@user, true) }
    first = ProductTour.page_guides_state(@user)
    # A later write whose request read an earlier clock still orders after.
    travel_to(1.minute.ago) { ProductTour.set_page_guides!(@user, false) }
    second = ProductTour.page_guides_state(@user)

    assert_equal [ true, false ], [ first[:page_guides], second[:page_guides] ]
    assert_operator first.fetch(:revision), :>, before.fetch(:revision)
    assert_operator second.fetch(:revision), :>, first.fetch(:revision)
  end

  test "a tour completed by the release before page guides leaves them off" do
    # Decided: that release writes only the outcome; such accounts keep the
    # default for existing accounts (manual guidance from Help).
    @user.update_columns(product_tour_version: ProductTour::VERSION, product_tour_outcome: "completed", product_tour_page_guides: false)
    assert_not ProductTour.page_guides_state(@user).fetch(:page_guides)
  end

  test "a page guide is recorded once; only finishing a dismissed guide changes it" do
    # The first write claims the page (the island opens a guide by itself
    # only when its claim, written as dismissed, created the row).
    assert ProductTour.record_page_outcome!(@user, "projects:list", "dismissed")
    assert_not ProductTour.record_page_outcome!(@user, "projects:list", "dismissed")
    assert ProductTour.record_page_outcome!(@user, "projects:list", "completed")
    assert_not ProductTour.record_page_outcome!(@user, "projects:list", "completed")
    assert_not ProductTour.record_page_outcome!(@user, "projects:list", "dismissed"), "completed is final"
    assert_equal [ [ "projects:list", "completed", ProductTour::PAGE_VERSION ] ], @user.product_tour_page_outcomes.pluck(:tour_key, :outcome, :version)
    assert ProductTour.page_seen?(@user, "projects:list")
    assert_not ProductTour.page_seen?(@user, "projects:detail")
    assert_raises(ArgumentError) { ProductTour.record_page_outcome!(@user, "projects:list", "preexisting") }
    assert_raises(ArgumentError) { ProductTour.record_page_outcome!(@user, "nowhere:list", "completed") }
  end

  test "a rewritten page guide has its own version, so only it opens again and older rows stay" do
    assert_equal ProductTour::PAGE_VERSION + 1, ProductTour.page_version("translation_workspaces:form")
    assert_equal ProductTour::PAGE_VERSION, ProductTour.page_version("projects:list")
    @user.product_tour_page_outcomes.create!(tour_key: "translation_workspaces:form", version: 1, outcome: "completed")
    @user.product_tour_page_outcomes.create!(tour_key: "projects:list", version: ProductTour::PAGE_VERSION, outcome: "completed")

    assert_not ProductTour.page_seen?(@user, "translation_workspaces:form")
    assert ProductTour.page_seen?(@user, "projects:list")
    assert ProductTour.record_page_outcome!(@user, "translation_workspaces:form", "dismissed")
    assert ProductTour.record_page_outcome!(@user, "translation_workspaces:form", "completed")
    assert_equal [ [ 1, "completed" ], [ 2, "completed" ] ],
      @user.product_tour_page_outcomes.where(tour_key: "translation_workspaces:form").order(:version).pluck(:version, :outcome)
  end

  test "repeated writes from several threads leave one row, and the database refuses a duplicate" do
    threads = 4.times.map do
      Thread.new { ActiveRecord::Base.connection_pool.with_connection { ProductTour.record_page_outcome!(@user, "history:list", "completed") } }
    end
    assert_equal 1, threads.map(&:value).count(true)
    assert_equal 1, @user.product_tour_page_outcomes.where(tour_key: "history:list").count
    assert_raises(ActiveRecord::RecordNotUnique) do
      ProductTourPageOutcome.create!(user: @user, tour_key: "history:list", version: ProductTour::PAGE_VERSION, outcome: "dismissed")
    end
  end

  test "completing the offered tour turns page guides on; dismissing it or replaying it does not" do
    assert ProductTour.record_outcome!(@user, "completed")
    assert @user.reload.product_tour_page_guides

    newcomer = users(:admin)
    newcomer.update_columns(product_tour_version: nil, product_tour_outcome: nil, product_tour_page_guides: false)
    ProductTour.record_outcome!(newcomer, "dismissed")
    assert_not newcomer.reload.product_tour_page_guides

    preexisting = users(:other)
    assert_not ProductTour.record_outcome!(preexisting, "completed")
    assert_not preexisting.reload.product_tour_page_guides, "an established account keeps manual guides"

    # A later tour version is offered again, but never overrides the switch.
    with_tour_version(ProductTour::VERSION + 1) do
      assert ProductTour.record_outcome!(preexisting, "completed")
    end
    assert_not preexisting.reload.product_tour_page_guides
  end

  test "the database rejects malformed page guide rows" do
    [ { tour_key: "Projects:list" }, { tour_key: "projects:edit" }, { outcome: "seen" }, { version: 0 } ].each do |attributes|
      row = { user: @user, tour_key: "projects:list", version: 1, outcome: "completed" }.merge(attributes)
      assert_raises(ActiveRecord::StatementInvalid, attributes.inspect) do
        ProductTourPageOutcome.transaction(requires_new: true) { ProductTourPageOutcome.create!(row) }
      end
    end
  end

  test "every page tour belongs to real controllers and every step is translated in each locale" do
    controllers = ProductTour::PAGE_TOURS.values.flat_map { |tour| tour[:controllers] }
    assert_equal controllers.uniq, controllers, "a controller maps to one page tour"
    controllers.each { |path| assert "#{path.camelize}Controller".safe_constantize, "#{path} is not a controller" }

    tours = { "global" => ProductTour::GLOBAL_STEPS }
    ProductTour::PAGE_TOURS.each { |key, tour| tours["pages.#{key}"] = tour[:steps] }
    User::SUPPORTED_LOCALES.each do |locale|
      tours.each do |scope, steps|
        assert steps.first[:targets].blank?, "#{scope} opens with a centered step that can always be shown"
        steps.each do |step|
          key = "product_tour.#{scope}.#{step[:id]}"
          assert I18n.exists?("#{key}.title", locale), "missing #{locale} #{key}.title"
          points = I18n.t("#{key}.points", locale: locale, default: nil)
          assert points.is_a?(Array) && (1..3).cover?(points.size) && points.all?(&:present?),
            "#{locale} #{key}.points has one to three short ideas"
        end
      end
    end
  end

  # A misspelled target would silently skip its step on every page.
  test "every tour target is marked somewhere in the application" do
    sources = Dir[Rails.root.join("app/{views,helpers}/**/*.{erb,rb}"), Rails.root.join("app/frontend/**/*.tsx")].map { |path| File.read(path) }.join("\n")
    targets = (ProductTour::GLOBAL_STEPS + ProductTour::PAGE_TOURS.values.flat_map { |tour| tour[:steps] }).flat_map { |step| step.fetch(:targets, []) }.uniq

    targets.each do |target|
      marked = sources.include?(%(data-tour-target="#{target}")) || sources.include?(%(tour_target: "#{target}")) || sources.include?(%(tour: "#{target}"))
      assert marked, "no element is marked data-tour-target=#{target}"
    end
  end

  test "tour and upload copy have the same keys and placeholders in every locale" do
    flatten = lambda do |hash, prefix = nil|
      hash.flat_map { |key, value| value.is_a?(Hash) ? flatten.call(value, [ prefix, key ].compact.join(".")) : [ [ [ prefix, key ].compact.join("."), value ] ] }
    end
    english = %i[product_tour file_field].to_h { |scope| [ scope, flatten.call(I18n.t(scope, locale: :en)).to_h ] }

    %i[vi ja].each do |locale|
      english.each do |scope, strings|
        translated = flatten.call(I18n.t(scope, locale: locale)).to_h
        assert_equal strings.keys.sort, translated.keys.sort, "#{locale} #{scope} keys"
        strings.each do |key, text|
          assert_equal text.to_s.scan(/%\{\w+\}/).sort, translated[key].to_s.scan(/%\{\w+\}/).sort, "#{locale} #{scope}.#{key} placeholders"
        end
      end
    end
  end

  private

  def with_tour_version(version)
    original = ProductTour::VERSION
    ProductTour.send(:remove_const, :VERSION)
    ProductTour.const_set(:VERSION, version)
    yield
  ensure
    ProductTour.send(:remove_const, :VERSION)
    ProductTour.const_set(:VERSION, original)
  end
end
