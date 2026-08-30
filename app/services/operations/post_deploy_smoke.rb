require "net/http"
require "uri"

module Operations
  class PostDeploySmoke
    Check = Data.define(:name, :status)
    Result = Data.define(:checks) do
      def successful?
        checks.all? { |check| check.status == "healthy" }
      end
    end

    def self.call(**options)
      new(**options).call
    end

    def initialize(base_url:, http_getter: nil, system_health: -> { Operations::SystemHealth.call }, allow_http: false)
      @base_uri = parse_base_url!(base_url, allow_http: allow_http)
      @http_getter = http_getter || method(:get_status)
      @system_health = system_health
    end

    def call
      checks = %w[/up /ready].map do |path|
        status = http_getter.call(base_uri.merge(path)).to_i == 200 ? "healthy" : "unavailable"
        Check.new(name: path.delete_prefix("/"), status: status)
      rescue StandardError
        Check.new(name: path.delete_prefix("/"), status: "unavailable")
      end
      system_health.call.checks.each do |dependency|
        checks << Check.new(name: dependency.name, status: dependency.status)
      end
      Result.new(checks: checks.freeze)
    end

    private

    attr_reader :base_uri, :http_getter, :system_health

    def parse_base_url!(value, allow_http:)
      uri = URI.parse(value.to_s)
      valid_scheme = uri.scheme == "https" || (allow_http && uri.scheme == "http")
      unless valid_scheme && uri.host.present? && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        raise ArgumentError, "a credential-free HTTPS base URL is required"
      end
      uri.path = "/"
      uri
    rescue URI::InvalidURIError
      raise ArgumentError, "a valid base URL is required"
    end

    def get_status(uri)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "text/plain"
      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: 5,
        read_timeout: 10
      ) { |http| http.request(request).code }
    end
  end
end
