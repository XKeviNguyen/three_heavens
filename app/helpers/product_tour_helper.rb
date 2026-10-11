# Server half of the product tour island: which tours apply to this page, their
# translated text, and whether the account is offered the global tour. Props
# hold only labels and element names, never account data.
module ProductTourHelper
  def product_tour_island
    react_island_tag "product-tour", props: product_tour_props, id: "product-tour", class: "relative flex-none"
  end

  private

  def product_tour_props
    page_key = ProductTour.page_tour_key(controller_path)
    {
      version: ProductTour::VERSION,
      offer: ProductTour.offered?(current_user),
      urls: { outcome: product_tour_path, start_translation: new_translation_workspace_path },
      messages: t("product_tour.ui"),
      tours: {
        global: product_tour_steps("global", ProductTour::GLOBAL_STEPS),
        page: page_key && product_tour_steps("pages.#{page_key}", ProductTour::PAGE_TOURS.fetch(page_key)[:steps])
      }
    }
  end

  def product_tour_steps(scope, steps)
    steps.map do |step|
      {
        id: step[:id],
        title: t("product_tour.#{scope}.#{step[:id]}.title"),
        body: t("product_tour.#{scope}.#{step[:id]}.body"),
        targets: step.fetch(:targets, [])
      }
    end
  end
end
