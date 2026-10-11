# Server-side half of the React islands foundation (app/frontend/islands).
# The fallback block is the server-rendered markup that stays in place until
# the island mounts, and that Turbo caches.
module ReactIslandsHelper
  def react_island_tag(name, props: {}, **html_options, &fallback_block)
    react_islands_javascript_tag
    data = (html_options.delete(:data) || {}).merge(react_island: name, react_props: props.to_json)
    tag.div(**html_options, data: data) { capture(&fallback_block) if fallback_block }
  end

  # Loads the bundle once per request. Deliberately not data-turbo-track: a
  # tracked script present on only some pages would force full reloads.
  def react_islands_javascript_tag
    return if @react_islands_javascript_included

    @react_islands_javascript_included = true
    content_for(:head, javascript_include_tag("islands", type: "module", nonce: true))
  end
end
