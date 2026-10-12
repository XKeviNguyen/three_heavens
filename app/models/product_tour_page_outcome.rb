# How an account resolved one contextual page guide (ProductTour::PAGE_TOURS),
# for one page context and guide version. Written only through
# ProductTour.record_page_outcome!, once per key and version.
class ProductTourPageOutcome < ApplicationRecord
  belongs_to :user
end
