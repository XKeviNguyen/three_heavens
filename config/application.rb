require_relative "boot"
require_relative "../app/middleware/request_body_limit"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ThreeHeavens
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1
    config.i18n.available_locales = %i[en vi ja]
    config.i18n.default_locale = :en

    # Reject declared oversized request bodies before multipart parsing or
    # application allocation, and bound the bytes read from requests without a
    # Content-Length. The outer instance wraps rack.input before Rack and
    # Action Dispatch can read it. The inner instance sits immediately inside
    # ActionDispatch::ShowExceptions so a bounded read during controller
    # parameter parsing still returns 413 instead of a generic error response.
    config.middleware.insert_before 0, RequestBodyLimit
    config.middleware.insert_after ActionDispatch::ShowExceptions, RequestBodyLimit

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Files are served only through owner-authorized application controllers.
    # This application does not use direct uploads or signed public blob routes.
    config.active_storage.draw_routes = false

    # Sign in with Google authenticates identity only. The OAuth client ID is a
    # public identifier; no client secret is used. Absent means Google is disabled.
    config.x.google_identity.client_id = ENV["GOOGLE_CLIENT_ID"].presence

    config.action_dispatch.default_headers.merge!(
      "Referrer-Policy" => "strict-origin-when-cross-origin",
      "X-Content-Type-Options" => "nosniff",
      "X-Frame-Options" => "DENY",
      "Permissions-Policy" => "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
    )

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
