require "test_helper"
require_relative "../../support/google_identity_test_helper"

class GoogleIdentity::SigningKeySourceTest < ActiveSupport::TestCase
  include GoogleIdentityTestHelper

  # Records Net::HTTP.start calls and answers GETs with a canned response.
  class FakeHttp
    attr_reader :calls

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
      @calls = []
    end

    def start(host, port, **options)
      @calls << [ host, port, options ]
      raise @error if @error

      response = @response
      yield(Object.new.tap { |http| http.define_singleton_method(:get) { |_path| response } })
    end
  end

  test "fetches Google's JWK set with bounded timeouts and refreshes at most once per interval" do
    jwk = JWT::JWK.new(GoogleIdentityTestHelper.google_key.public_key, kid: TEST_KEY_ID).export.merge(alg: "RS256", use: "sig")
    http = FakeHttp.new(response: success_response({ keys: [ jwk ] }.to_json))
    now = Time.current
    source = GoogleIdentity::SigningKeySource.new(http: http, clock: -> { now })

    assert_equal [ TEST_KEY_ID ], source.refresh_keys.map(&:id)
    source.refresh_keys
    now += GoogleIdentity::SigningKeySource::REFRESH_INTERVAL + 1
    source.refresh_keys

    assert_equal 2, http.calls.size
    assert_equal [ "www.googleapis.com", 443, { use_ssl: true, open_timeout: 3, read_timeout: 5 } ], http.calls.first
  end

  test "keys older than the maximum age are no longer trusted until refreshed" do
    jwk = JWT::JWK.new(GoogleIdentityTestHelper.google_key.public_key, kid: TEST_KEY_ID).export.merge(alg: "RS256", use: "sig")
    now = Time.current
    source = GoogleIdentity::SigningKeySource.new(http: FakeHttp.new(response: success_response({ keys: [ jwk ] }.to_json)), clock: -> { now })

    assert_empty source.current_keys
    source.refresh_keys
    assert_equal [ TEST_KEY_ID ], source.current_keys.map(&:id)
    now += GoogleIdentity::SigningKeySource::MAXIMUM_KEY_AGE + 1
    assert_empty source.current_keys
  end

  test "network, HTTP, and parse failures surface as key-source errors" do
    [ FakeHttp.new(error: Net::OpenTimeout), FakeHttp.new(error: Net::ReadTimeout), FakeHttp.new(error: SocketError),
      FakeHttp.new(response: Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable")),
      FakeHttp.new(response: success_response("not json")) ].each do |http|
      assert_raises(Google::Auth::IDTokens::KeySourceError) { GoogleIdentity::SigningKeySource.new(http: http).refresh_keys }
    end
  end

  private

  def success_response(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap do |response|
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)
    end
  end
end
