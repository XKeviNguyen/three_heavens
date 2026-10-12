require "test_helper"
require Rails.root.join("db/migrate/20261012090000_create_product_tour_page_outcomes")

class CreateProductTourPageOutcomesTest < ActiveSupport::TestCase
  teardown { User.reset_column_information }

  test "existing accounts keep their tour state and start with page guides off" do
    migration = CreateProductTourPageOutcomes.new
    migration.verbose = false
    migration.down
    User.reset_column_information
    before = User.order(:id).pluck(:id, :product_tour_version, :product_tour_outcome)
    assert_not ActiveRecord::Base.connection.table_exists?(:product_tour_page_outcomes)

    migration.up
    User.reset_column_information

    assert_equal before, User.order(:id).pluck(:id, :product_tour_version, :product_tour_outcome)
    assert_equal [ false ], User.distinct.pluck(:product_tour_page_guides)
    assert_equal 0, ProductTourPageOutcome.count
  end
end
