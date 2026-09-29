require "net/http"

# Automated tests must never reach an external service (OpenRouter's catalog
# or completions, Google, email). Connections are allowed only to loopback,
# which Selenium's driver and Capybara's server use.
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
