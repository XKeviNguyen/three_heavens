# Stands in for the Cloudflare edge plus cloudflared: runs in a container on
# the same Docker network as kamal-proxy (so its address is private, like the
# cloudflared connector) and sends each request to http://PROXY:80 with the
# headers Cloudflare documents for a visitor at CLIENT_IP:
#   X-Forwarded-For: <client-supplied value>, CLIENT_IP  (appended)
#   CF-Connecting-IP: CLIENT_IP                           (overwritten)
#   X-Forwarded-Proto: https                              (overwritten)
# Client-Ip and True-Client-IP from the client are passed through unchanged
# (worst case: assume Cloudflare does not strip them).
#
# Run by run.sh: ruby edge.rb echo|app PROXY_HOST EXPECT BASE_OCTET
# EXPECT is "isolated" for the committed configuration (Rails must see each
# visitor's own address, which headers cannot change, and budgets must stay
# independent) or "shared" for the control with forwarding off (Rails must
# see this container's address for everyone), which proves the evaluation
# can tell the two apart. Prints what it observed, then exits nonzero listing
# every expectation that did not hold.
require "json"
require "net/http"
require "socket"

module TunnelEdge
  APP_HOST = "threeheavens.test"
  FAILED = "422"
  THROTTLED = "429"
  LIMIT = 10 # SessionsController::LOGIN_RATE_LIMIT

  module_function

  def ip(base, offset) = "198.51.100.#{base + offset}"

  def spoof(value)
    { "X-Forwarded-For" => value, "Client-Ip" => value, "True-Client-IP" => value, "CF-Connecting-IP" => value }
  end

  def echo_cases(base)
    {
      "plain client" => [ ip(base, 1), {} ],
      "client spoofing 203.0.113.9 in every IP header" => [ ip(base, 1), spoof("203.0.113.9") ],
      "client spoofing private/loopback chain" => [ ip(base, 1), spoof("10.0.0.1, 127.0.0.1, 172.18.0.2") ],
      "client spoofing another visitor" => [ ip(base, 1), spoof(ip(base, 2)) ]
    }
  end

  # The status sequence each sign-in scenario must produce.
  def expected_sign_ins(expect)
    limited = [ FAILED ] * LIMIT + [ THROTTLED ]
    case expect
    when "isolated"
      { "A" => limited, "B" => [ FAILED ], "C" => limited, "D" => limited, "E" => [ FAILED ] }
    when "shared"
      # Everyone shares the stand-in's budget, so A spends it and the
      # distinct visitors after A are refused.
      { "A" => limited, "B" => [ THROTTLED ], "E" => [ THROTTLED ] }
    else
      raise ArgumentError, "EXPECT must be isolated or shared, not #{expect.inspect}"
    end
  end

  # observed: case label => [client_ip, remote_ip Rails derived]
  def echo_failures(expect, observed, edge_address)
    expected_sign_ins(expect) # validates EXPECT
    observed.filter_map do |label, (client_ip, remote_ip)|
      wanted = expect == "isolated" ? client_ip : edge_address
      "echo #{label}: Rails saw #{remote_ip.inspect}, expected #{wanted.inspect}" unless remote_ip == wanted
    end
  end

  # observed: scenario => status codes in order
  def sign_in_failures(expect, observed)
    expected_sign_ins(expect).filter_map do |scenario, wanted|
      actual = observed[scenario]
      "sign-in #{scenario}: got #{actual.inspect}, expected #{wanted.inspect}" unless actual == wanted
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  PHASE, PROXY, EXPECT, BASE = ARGV
  BASE_OCTET = Integer(BASE)
  include TunnelEdge

  def cloudflare(client_ip, supplied = {})
    supplied = supplied.dup
    spoofed_forwarded_for = supplied.delete("X-Forwarded-For")
    supplied.delete("CF-Connecting-IP")
    supplied.merge(
      "Host" => TunnelEdge::APP_HOST,
      "X-Forwarded-For" => [ spoofed_forwarded_for, client_ip ].compact.join(", "),
      "CF-Connecting-IP" => client_ip,
      "X-Forwarded-Proto" => "https"
    )
  end

  def http = Net::HTTP.new(PROXY, 80).tap { |connection| connection.open_timeout = connection.read_timeout = 30 }

  def failed_sign_in(client_ip, email, supplied = {})
    headers = cloudflare(client_ip, supplied)
    page = http.request(Net::HTTP::Get.new("/login", headers))
    raise "GET /login #{page.code}" unless page.code == "200"

    cookie = page.get_fields("set-cookie").map { |value| value.split(";").first }.join("; ")
    token = page.body[/name="csrf-token" content="([^"]+)"/, 1]
    post = Net::HTTP::Post.new("/session", headers.merge("Cookie" => cookie))
    post.set_form_data("authenticity_token" => token, "session[email]" => email, "session[password]" => "wrong password value")
    http.request(post).code
  end

  def attempts(count, client_ip, label, &supplied)
    Array.new(count) do |index|
      failed_sign_in(client_ip, "probe-#{EXPECT}-#{BASE}-#{label}-#{index}@example.test", supplied ? supplied.call(index) : {})
    end
  end

  # This container's address on the Docker network, as kamal-proxy sees it.
  edge_address = UDPSocket.open { |socket| socket.connect(PROXY, 80) && socket.addr.last }

  failures = case PHASE
  when "echo"
    require "bundler/setup"
    require "action_dispatch"
    require "/rails/app/middleware/client_ip_header_filter"
    rails = ClientIpHeaderFilter.new(ActionDispatch::RemoteIp.new(->(env) { [ 200, {}, [ ActionDispatch::Request.new(env).remote_ip ] ] }, true, nil))
    observed = echo_cases(BASE_OCTET).to_h do |label, (client_ip, supplied)|
      response = http.request(Net::HTTP::Get.new("/probe", cloudflare(client_ip, supplied)))
      seen = JSON.parse(response.body)
      env = { "REMOTE_ADDR" => seen["remote_addr"], "HTTP_X_FORWARDED_FOR" => seen.dig("headers", "x-forwarded-for") }
      env["HTTP_CLIENT_IP"] = seen.dig("headers", "client-ip") if seen.dig("headers", "client-ip")
      remote_ip = begin
        rails.call(env).last.first
      rescue ActionDispatch::RemoteIp::IpSpoofAttackError => error
        "IpSpoofAttackError: #{error.message}"
      end
      puts JSON.generate("expect" => EXPECT, "case" => label, "client" => client_ip, "at_puma" => seen, "rails_remote_ip" => remote_ip)
      [ label, [ client_ip, remote_ip ] ]
    end
    echo_failures(EXPECT, observed, edge_address)
  when "app"
    observed = { "A" => attempts(LIMIT + 1, ip(BASE_OCTET, 1), "a"), "B" => attempts(1, ip(BASE_OCTET, 2), "b") }
    if EXPECT == "isolated"
      # C rotates spoofed addresses; D claims victim E's address, then a
      # private/loopback chain; E must keep its own budget afterwards.
      observed["C"] = attempts(LIMIT + 1, ip(BASE_OCTET, 3), "c") { |index| spoof("203.0.113.#{index + 1}") }
      observed["D"] = attempts(LIMIT + 1, ip(BASE_OCTET, 4), "d") { |index| spoof(index.even? ? ip(BASE_OCTET, 5) : "10.0.0.1, 127.0.0.1") }
    end
    observed["E"] = attempts(1, ip(BASE_OCTET, 5), "e")
    puts JSON.pretty_generate("expect" => EXPECT, "edge_address" => edge_address, "sign_ins" => observed)
    sign_in_failures(EXPECT, observed)
  else
    abort "usage: ruby edge.rb echo|app PROXY_HOST isolated|shared BASE_OCTET"
  end

  if failures.any?
    warn "FAIL (#{PHASE}, #{EXPECT}):", *failures.map { |failure| "  #{failure}" }
    exit 1
  end
  puts "PASS (#{PHASE}, #{EXPECT})"
end
