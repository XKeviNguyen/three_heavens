require "active_support/core_ext/integer/time"

Rails.application.configure do
  asset_build = ENV["SECRET_KEY_BASE_DUMMY"].present?
  production_host = ENV["APP_HOST"].presence
  raise "APP_HOST is required in production" if production_host.nil? && !asset_build
  production_host ||= "localhost"

  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  config.ssl_options = {
    hsts: { expires: 1.year, subdomains: true, preload: false },
    redirect: { exclude: ->(request) { request.path.in?([ "/up", "/ready" ]) } }
  }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with a durable alternative.
  config.cache_store = :solid_cache_store

  # Replace the default in-process and non-durable queuing backend for Active Job.
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: production_host, protocol: "https" }

  # Confirmation links use APP_HOST above, never the inbound Host header.
  unless asset_build
    %w[MAIL_FROM SMTP_HOST SMTP_USERNAME SMTP_PASSWORD].each do |name|
      raise "#{name} is required in production" if ENV[name].blank?
    end
  end
  if ENV["SMTP_HOST"].present?
    smtp_port = Integer(ENV.fetch("SMTP_PORT", "587"), 10, exception: false)
    raise "SMTP_PORT must be a port number in production" unless smtp_port&.between?(1, 65_535)

    config.action_mailer.delivery_method = :smtp
    config.action_mailer.raise_delivery_errors = true
    # Credentials never cross the network unencrypted. Port 465 (SMTPS) speaks
    # TLS from its first byte; every other port must upgrade with STARTTLS,
    # and delivery fails rather than authenticating in the clear when the
    # server (or anything in between) does not offer it.
    config.action_mailer.smtp_settings = {
      address: ENV.fetch("SMTP_HOST"),
      port: smtp_port,
      user_name: ENV.fetch("SMTP_USERNAME"),
      password: ENV.fetch("SMTP_PASSWORD"),
      authentication: :plain
    }.merge(smtp_port == 465 ? { tls: true } : { enable_starttls: :always })
  end

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Kamal Proxy's liveness check reaches /up by container address, so /up is
  # exempt. Readiness is probed publicly with Host APP_HOST or from inside the
  # container over loopback (docs/operations/production-deploy.md); every
  # other Host is still refused, for /ready and for all application traffic.
  # The loopback check reads the raw Host header, not request.host, which
  # would honour X-Forwarded-Host or fall back to the server name when Host is
  # missing; a forwarded request never qualifies.
  readiness_probe_hosts = %w[localhost 127.0.0.1 [::1]].freeze
  loopback_readiness_probe = lambda do |request|
    host = request.get_header("HTTP_HOST").to_s[/\A(\[[^\]]*\]|[^:\[\]]+)(?::\d+)?\z/, 1]
    request.get_header("HTTP_X_FORWARDED_HOST").blank? && readiness_probe_hosts.include?(host&.downcase)
  end
  config.hosts = [ production_host ]
  config.host_authorization = {
    exclude: ->(request) { request.path == "/up" || (request.path == "/ready" && loopback_readiness_probe.call(request)) }
  }
end
