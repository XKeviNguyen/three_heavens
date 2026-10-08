require "net/http"

# Ruby code under test must never reach an external service (OpenRouter's
# catalog or completions, Google, email): Net::HTTP may connect only to
# loopback, which Selenium's driver and Capybara's server use. It does not
# cover the browser itself or the Selenium Manager binary; system tests block
# Google in the browser and disable Selenium Manager's usage statistics.
module NetworkGuard
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

  private

  def connect
    host = address.to_s.delete_prefix("[").delete_suffix("]")
    raise "Tests may not open a network connection to #{address}" unless LOOPBACK_HOSTS.include?(host)

    super
  end
end

Net::HTTP.prepend(NetworkGuard)
