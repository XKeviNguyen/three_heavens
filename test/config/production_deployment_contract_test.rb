require "test_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# The tracked Kamal configuration must supply every variable production needs
# to boot, and production must refuse to boot when any of them is missing.
# Everything here uses dummy values: no real secret, SMTP server, database, or
# provider is contacted, the operator's secrets file is never evaluated, and
# production boots from a disposable copy of the application whose
# credentials are encrypted with a dummy master key, so the real key and
# credentials are never read.
class ProductionDeploymentContractTest < ActiveSupport::TestCase
  # What an operator's workstation provides when running `bin/kamal deploy`.
  DEPLOY_ENVIRONMENT = {
    "KAMAL_WEB_HOST" => "192.0.2.10",
    "APP_HOST" => "app.example.test",
    "KAMAL_IMAGE" => "contract/three_heavens",
    "KAMAL_REGISTRY_SERVER" => "registry.example.test",
    "KAMAL_REGISTRY_USERNAME" => "contract-registry-user",
    "MAIL_FROM" => "Three Heavens <no-reply@example.test>",
    "SMTP_HOST" => "smtp.example.test"
  }.freeze
  BOOT_REQUIRED = %w[
    APP_HOST DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL
    MAIL_FROM SMTP_HOST SMTP_USERNAME SMTP_PASSWORD
  ].freeze
  # Only toolchain variables reach the subprocesses, never this test process's
  # database credentials or Rails environment.
  TOOLCHAIN_VARIABLE = /\A(PATH|HOME|LANG|LC_ALL|TMPDIR|BUNDLE_.*|GEM_.*|RUBY.*|MISE_.*)\z/

  RENDER_SCRIPT = <<~'RUBY'
    require "json"
    require "kamal"
    require "tempfile"

    raw = Kamal::Configuration.load_raw_config(config_file: Pathname.new("config/deploy.yml"))
    secrets = Tempfile.new("contract-secrets")
    raw.fetch(:env).fetch("secret").each do |name|
      value = name == "RAILS_MASTER_KEY" ? ENV.fetch("CONTRACT_MASTER_KEY") : "contract-secret-#{name.downcase}"
      secrets.puts("#{name}=#{value}")
    end
    secrets.flush
    raw[:secrets_path] = secrets.path
    config = Kamal::Configuration.new(raw, version: "contract")
    role = config.role(:web)
    puts JSON.generate(secret_names: raw.fetch(:env).fetch("secret"), env: role.env(config.primary_host).to_h)
  RUBY

  BOOT_SCRIPT = <<~'RUBY'
    require "rack/mock"
    host = ENV.fetch("APP_HOST")
    up_status, = Rails.application.call(Rack::MockRequest.env_for("https://#{host}/up", "HTTP_HOST" => host))
    json_status = lambda do |body|
      status, = Rails.application.call(Rack::MockRequest.env_for("https://#{host}/translation_workspace_draft",
        method: "POST", input: body, "HTTP_HOST" => host, "CONTENT_TYPE" => "application/json"))
      status
    end
    settings = ActionMailer::Base.smtp_settings
    # A stand-in for a user, since no database is reachable here.
    reader = Struct.new(:email, :locale) { def generate_token_for(_purpose) = "contract-token" }
    message = AccountMailer.confirm_email(reader.new("reader@example.test", "en")).message
    puts "BOOT_RESULT=" + JSON.generate(
      up: up_status,
      wide_json: json_status.call("[" + ("{}," * 5_000) + "{}]"),
      oversized_json: json_status.call("[" + ("{}," * 200_000) + "{}]"),
      delivery_method: ActionMailer::Base.delivery_method,
      raise_delivery_errors: ActionMailer::Base.raise_delivery_errors,
      smtp_matches_environment: settings[:address] == ENV["SMTP_HOST"] && settings[:port] == Integer(ENV["SMTP_PORT"]) &&
        settings[:user_name] == ENV["SMTP_USERNAME"] && settings[:password] == ENV["SMTP_PASSWORD"],
      from: message[:from].to_s,
      confirmation_link_https_app_host: message.text_part.decoded.include?("https://#{host}/email_confirmation?token=")
    )
  RUBY

  test "the rendered Kamal environment supplies every variable production requires" do
    rendered = render_deploy_configuration
    names = rendered.fetch("env").keys

    assert_empty (Operations::Preflight::REQUIRED_ENVIRONMENT_NAMES - names), "deploy.yml does not pass them to the container"
    assert_includes rendered.fetch("secret_names"), "SMTP_PASSWORD"
    assert_includes rendered.fetch("secret_names"), "SMTP_USERNAME"
    assert_equal DEPLOY_ENVIRONMENT.fetch("MAIL_FROM"), rendered.dig("env", "MAIL_FROM")
    assert_equal [ "smtp.example.test", "587", "app.example.test" ], rendered.fetch("env").values_at("SMTP_HOST", "SMTP_PORT", "APP_HOST")
  end

  test "deploy.yml keeps credential-bearing mail settings out of clear environment" do
    deploy = Rails.root.join("config/deploy.yml").read

    assert_no_match(/^\s+SMTP_(USERNAME|PASSWORD):/, deploy)
    assert_match(/^\s+- SMTP_PASSWORD$/, deploy)
  end

  test "production boots with only the rendered deployment environment and fails clearly without each required variable" do
    master_key = SecureRandom.hex(16)
    # The image sets RAILS_ENV; Kamal passes every value as a string.
    container = render_deploy_configuration(master_key:).fetch("env").transform_values(&:to_s).merge("RAILS_ENV" => "production")

    with_disposable_application(master_key) do |root|
      stdout, stderr, status = boot(root, container, BOOT_SCRIPT)
      assert status.success?, "production did not boot: #{stderr.lines.first(2).join}"
      result = JSON.parse(stdout.lines.find { |line| line.start_with?("BOOT_RESULT=") }.delete_prefix("BOOT_RESULT="))
      assert_equal(
        { "up" => 200, "wide_json" => 400, "oversized_json" => 413, "delivery_method" => "smtp", "raise_delivery_errors" => true, "smtp_matches_environment" => true,
          "from" => "Three Heavens <no-reply@example.test>", "confirmation_link_https_app_host" => true },
        result
      )
      assert_no_secret_values(stdout + stderr, container)

      BOOT_REQUIRED.each do |name|
        stdout, stderr, status = boot(root, container.except(name), "puts :booted")

        assert_not status.success?, "production booted without #{name}"
        assert_match(/#{name}/, stderr, "the failure does not name #{name}")
        assert_no_secret_values(stdout + stderr, container)
      end
    end
  end

  private

  def render_deploy_configuration(master_key: SecureRandom.hex(16))
    environment = toolchain_environment.merge(DEPLOY_ENVIRONMENT).merge("CONTRACT_MASTER_KEY" => master_key)
    stdout, stderr, status = Open3.capture3(environment, RbConfig.ruby, "-rbundler/setup", "-e", RENDER_SCRIPT,
                                            chdir: Rails.root.to_s, unsetenv_others: true)
    assert status.success?, "Kamal could not render config/deploy.yml: #{stderr.lines.last(3).join}"
    JSON.parse(stdout.lines.last)
  end

  # A copy of the working tree without any key or the real credentials, with
  # credentials that hold only a dummy secret_key_base under `master_key`.
  def with_disposable_application(master_key)
    Dir.mktmpdir("production-contract") do |root|
      files = IO.popen([ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" ], chdir: Rails.root.to_s, &:read).split("\0")
      files.reject { |path| path.end_with?(".key") || path.start_with?("config/credentials") }.each do |path|
        source = Rails.root.join(path)
        next unless source.file?

        FileUtils.mkdir_p(File.join(root, File.dirname(path)))
        FileUtils.cp(source, File.join(root, path), preserve: true)
      end
      Dir.mktmpdir("production-contract-key") do |key_directory|
        key_path = File.join(key_directory, "master.key")
        File.write(key_path, master_key)
        ActiveSupport::EncryptedConfiguration.new(
          config_path: File.join(root, "config/credentials.yml.enc"), key_path:,
          env_key: "PRODUCTION_CONTRACT_UNUSED_KEY", raise_if_missing_key: true
        ).write("secret_key_base: #{SecureRandom.hex(64)}\n")
      end
      yield root
    end
  end

  # BUNDLE_GEMFILE keeps the copy on this checkout's installed bundle.
  def boot(root, environment, script)
    environment = toolchain_environment.merge("BUNDLE_GEMFILE" => Rails.root.join("Gemfile").to_s).merge(environment)
    Open3.capture3(environment, "bin/rails", "runner", script, chdir: root, unsetenv_others: true)
  end

  def toolchain_environment
    ENV.to_h.select { |name, _| name.match?(TOOLCHAIN_VARIABLE) }
  end

  def assert_no_secret_values(output, environment)
    environment.each do |name, value|
      next unless value.to_s.start_with?("contract-secret")

      assert_not_includes output, value, "#{name} leaked into output"
    end
  end
end
