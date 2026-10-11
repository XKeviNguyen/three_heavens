# Prints what `bin/kamal deploy` would use for kamal-proxy, rendered by Kamal
# from this checkout's config/deploy.yml with dummy deployment values, so the
# evaluation exercises the committed settings rather than a copy of them.
# The operator's secrets file is never read.
#
#   ruby kamal_proxy.rb image            # the kamal-proxy image Kamal boots
#   ruby kamal_proxy.rb deploy TARGET    # the kamal-proxy deploy command for container TARGET
require "kamal"
require "tempfile"

{
  "KAMAL_WEB_HOST" => "192.0.2.10", "APP_HOST" => "threeheavens.test", "KAMAL_IMAGE" => "evaluation/three_heavens",
  "KAMAL_REGISTRY_SERVER" => "registry.example.invalid", "KAMAL_REGISTRY_USERNAME" => "evaluation",
  "MAIL_FROM" => "tunnel@example.invalid", "SMTP_HOST" => "smtp.example.invalid",
  "GOOGLE_CLIENT_ID" => "unused.apps.googleusercontent.com"
}.each { |name, value| ENV[name] = value }

raw = Kamal::Configuration.load_raw_config(config_file: Pathname.new(File.expand_path("../../../config/deploy.yml", __dir__)))
raw[:secrets_path] = Tempfile.new("evaluation-secrets").path
config = Kamal::Configuration.new(raw, version: "evaluation")
host = config.primary_host

case ARGV
in [ "image" ]
  puts config.proxy_run(host).image
in [ "deploy", target ]
  command = Kamal::Commands::App.new(config, role: config.role(:web), host:).deploy(target:).flatten.map(&:to_s)
  # Drop `docker exec kamal-proxy`; run.sh executes the rest inside its proxy
  # container through a shell, as Kamal does over SSH.
  puts command.drop(3).join(" ")
end
