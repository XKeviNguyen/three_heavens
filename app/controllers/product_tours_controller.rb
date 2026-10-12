# Records the signed-in account's product tour progress. Every action writes
# only the current user's own rows and columns; nothing here starts AI work or
# changes anything else.
class ProductToursController < ApplicationController
  # The island may send these as the page unloads (keepalive); a session
  # written here could overwrite a newer one.
  before_action { request.session_options[:skip] = true }

  rate_limit to: 10, within: 1.minute, by: -> { current_user.id }, name: "product_tour", only: :update,
             with: -> { head :too_many_requests }
  rate_limit to: 10, within: 1.minute, by: -> { current_user.id }, name: "product_tour_preference", only: :preference,
             with: -> { head :too_many_requests }
  # One write per page guide ended; visiting many pages quickly stays allowed.
  rate_limit to: 60, within: 1.minute, by: -> { current_user.id }, name: "product_tour_page", only: :page,
             with: -> { head :too_many_requests }

  # The global tour's offer: completed or dismissed, once per version. Answers
  # with the page-guides switch as stored, since another tab may have resolved
  # the offer first.
  def update
    attributes = params.expect(product_tour: %i[outcome version])
    outcome = known_outcome!(attributes[:outcome])
    # A page rendered before the tour changed must not resolve the new one.
    return head :conflict unless attributes[:version].to_s == ProductTour::VERSION.to_s

    ProductTour.record_outcome!(current_user, outcome)
    render json: ProductTour.page_guides_state(current_user)
  end

  # A page guide ended: remembered so it does not open by itself again.
  def page
    attributes = params.expect(product_tour_page: %i[key outcome version])
    outcome = known_outcome!(attributes[:outcome])
    key = attributes[:key].to_s
    raise ActionController::BadRequest, "Unknown page guide" unless ProductTour.valid_page_key?(key)
    return head :conflict unless attributes[:version].to_s == ProductTour::PAGE_VERSION.to_s

    ProductTour.record_page_outcome!(current_user, key, outcome)
    head :no_content
  end

  # Help → "Show page guides automatically". Answers with the stored switch and
  # its stamp (see ProductTour.page_guides_state).
  def preference
    enabled = params.expect(product_tour_preference: [ :page_guides ])[:page_guides]
    raise ActionController::BadRequest, "page_guides must be true or false" unless [ true, false ].include?(enabled)

    ProductTour.set_page_guides!(current_user, enabled)
    render json: ProductTour.page_guides_state(current_user)
  end

  private

  def known_outcome!(value)
    value.to_s.tap do |outcome|
      raise ActionController::BadRequest, "Unknown product tour outcome" unless ProductTour::OUTCOMES.include?(outcome)
    end
  end
end
