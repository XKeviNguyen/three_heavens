# Server half of the product tour island: which tours apply to this page, their
# translated text, whether the account is offered the global tour, and whether
# this page's guide should open by itself. Props hold only labels, element
# names, and the account's own guide state, never other account data.
module ProductTourHelper
  def product_tour_island
    react_island_tag "product-tour", props: product_tour_props, id: "product-tour", class: "relative block min-h-[47px]"
  end

  private

  def product_tour_props
    page_family = ProductTour.page_tour_key(controller_path)
    page_key = ProductTour.page_context_key(controller_path, action_name, request.request_method)
    {
      version: ProductTour::VERSION,
      offer: ProductTour.offered?(current_user),
      urls: {
        outcome: product_tour_path, page: page_product_tour_path, preference: preference_product_tour_path,
        start_translation: new_translation_workspace_path
      },
      messages: t("product_tour.ui"),
      # Queried even with the switch off: turning it on from another page may
      # let this page's guide open once that change is saved.
      page_guides: { enabled: current_user.product_tour_page_guides, revision: current_user.product_tour_guides_revision,
                     key: page_key, version: page_key ? ProductTour.page_version(page_key) : ProductTour::PAGE_VERSION,
                     seen: page_key ? ProductTour.page_seen?(current_user, page_key) : false },
      tours: {
        global: product_tour_steps("global", ProductTour::GLOBAL_STEPS),
        page: page_family && product_tour_steps("pages.#{page_family}", ProductTour::PAGE_TOURS.fetch(page_family)[:steps])
      }
    }
  end

  # Each step is a short title and one to three points, one idea each.
  def product_tour_steps(scope, steps)
    steps.map do |step|
      {
        id: step[:id],
        title: t("product_tour.#{scope}.#{step[:id]}.title"),
        points: Array(t("product_tour.#{scope}.#{step[:id]}.points")),
        targets: step.fetch(:targets, [])
      }
    end
  end
end
