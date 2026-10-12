require "test_helper"
require Rails.root.join("db/migrate/20261012110000_mark_tours_completed_before_page_guides")

class MarkToursCompletedBeforePageGuidesTest < ActiveSupport::TestCase
  test "tours completed before the deploy keep page guides off; later completions by the old release turn them on" do
    earlier = users(:normal)
    earlier.update_columns(product_tour_version: ProductTour::VERSION, product_tour_outcome: "completed")
    untouched = users(:other).product_tour_guides_revision

    migration = MarkToursCompletedBeforePageGuides.new
    migration.verbose = false
    migration.up

    assert_not ProductTour.page_guides_enabled?(earlier.reload)
    assert_equal untouched, users(:other).reload.product_tour_guides_revision, "unresolved and preexisting accounts are unchanged"

    later = users(:admin)
    later.update_columns(product_tour_version: ProductTour::VERSION, product_tour_outcome: "completed")
    assert ProductTour.page_guides_enabled?(later.reload)
  end
end
