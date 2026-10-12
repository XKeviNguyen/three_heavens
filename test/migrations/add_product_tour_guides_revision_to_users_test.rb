require "test_helper"
require Rails.root.join("db/migrate/20261012100000_add_product_tour_guides_revision_to_users")

class AddProductTourGuidesRevisionToUsersTest < ActiveSupport::TestCase
  teardown { User.reset_column_information }

  test "tours completed before it keep page guides off; completions by the old release after it turn them on" do
    migration = AddProductTourGuidesRevisionToUsers.new
    migration.verbose = false
    migration.down
    User.reset_column_information
    earlier = users(:normal)
    earlier.update_columns(product_tour_version: ProductTour::VERSION, product_tour_outcome: "completed")
    before = User.order(:id).pluck(:id, :product_tour_page_guides)

    migration.up
    User.reset_column_information

    assert_equal before, User.order(:id).pluck(:id, :product_tour_page_guides)
    assert_equal 1, earlier.reload.product_tour_guides_revision
    assert_not ProductTour.page_guides_enabled?(earlier)
    assert_equal [ 0 ], User.where.not(id: earlier.id).distinct.pluck(:product_tour_guides_revision), "other accounts start at zero"

    # The old release, still serving after this migration commits, writes
    # only the outcome; nothing runs afterwards that could mark it.
    later = users(:admin)
    later.update_columns(product_tour_version: ProductTour::VERSION, product_tour_outcome: "completed")
    assert ProductTour.page_guides_enabled?(later.reload)
  end
end
