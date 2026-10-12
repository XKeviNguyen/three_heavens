require "test_helper"
require Rails.root.join("db/migrate/20261012100000_add_product_tour_guides_revision_to_users")

class AddProductTourGuidesRevisionToUsersTest < ActiveSupport::TestCase
  teardown { User.reset_column_information }

  test "existing accounts keep their switch and start at revision zero" do
    migration = AddProductTourGuidesRevisionToUsers.new
    migration.verbose = false
    migration.down
    User.reset_column_information
    before = User.order(:id).pluck(:id, :product_tour_page_guides)

    migration.up
    User.reset_column_information

    assert_equal before, User.order(:id).pluck(:id, :product_tour_page_guides)
    assert_equal [ 0 ], User.distinct.pluck(:product_tour_guides_revision)
  end
end
