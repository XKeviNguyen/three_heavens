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
          %w[title body].each do |part|
            key = "product_tour.#{scope}.#{step[:id]}.#{part}"
            assert I18n.exists?(key, locale), "missing #{locale} #{key}"
          end
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
end
