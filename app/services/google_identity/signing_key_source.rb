module GoogleIdentity
  # Google's rotating OIDC signing keys for googleauth's verifier. googleauth
  # performs all JWT signature and claim checks; this source exists only to
  # fetch the public JWK set with explicit timeouts and a bounded refresh rate.
  class SigningKeySource
    CERTS_URI = URI(Google::Auth::IDTokens::OAUTH2_V3_CERTS_URL)
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5
    # Unknown or forged key IDs can trigger at most one refresh per interval.
    REFRESH_INTERVAL = 60
    # Keys older than this are refreshed, so keys Google has withdrawn stop
    # being trusted even while verification keeps succeeding.
    MAXIMUM_KEY_AGE = 1.hour

    def initialize(uri: CERTS_URI, http: Net::HTTP, clock: -> { Time.current })
      @uri = uri
      @http = http
      @clock = clock
      @current_keys = []
      @fetched_at = nil
      @refresh_allowed_at = nil
      @monitor = Monitor.new
    end

    def current_keys
      return [] if @fetched_at.nil? || @clock.call - @fetched_at > MAXIMUM_KEY_AGE

      @current_keys
    end

    def refresh_keys
      @monitor.synchronize do
        return @current_keys if @refresh_allowed_at && @clock.call < @refresh_allowed_at

        @refresh_allowed_at = @clock.call + REFRESH_INTERVAL
        @current_keys = Array(Google::Auth::IDTokens::KeyInfo.from_jwk_set(fetch_key_set))
        @fetched_at = @clock.call
        @current_keys
      end
    end

    private

    def fetch_key_set
      response = @http.start(@uri.host, @uri.port, use_ssl: true,
                             open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.get(@uri.request_uri)
      end
      raise Google::Auth::IDTokens::KeySourceError, "Google signing keys unavailable" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError, Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError
      raise Google::Auth::IDTokens::KeySourceError, "Google signing keys unavailable"
    end
  end
end
