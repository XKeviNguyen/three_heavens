# Records how the signed-in account resolved the offered product tour. It
# only ever writes the current user's own onboarding columns.
class ProductToursController < ApplicationController
  # The island may send this as the page unloads (keepalive); a session
  # written here could overwrite a newer one.
  before_action { request.session_options[:skip] = true }

  rate_limit to: 10, within: 1.minute, by: -> { current_user.id }, name: "product_tour",
             with: -> { head :too_many_requests }

  def update
    attributes = params.expect(product_tour: %i[outcome version])
    outcome = attributes[:outcome].to_s
    raise ActionController::BadRequest, "Unknown product tour outcome" unless ProductTour::OUTCOMES.include?(outcome)
    # A page rendered before the tour changed must not resolve the new one.
    return head :conflict unless attributes[:version].to_s == ProductTour::VERSION.to_s

    ProductTour.record_outcome!(current_user, outcome)
    head :no_content
  end
end
