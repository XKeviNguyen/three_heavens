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
# Run by run.sh: ruby edge.rb echo|app PROXY_HOST MODE_LABEL BASE_OCTET
require "json"
require "net/http"

PHASE, PROXY, MODE, BASE = ARGV
BASE_OCTET = Integer(BASE)
APP_HOST = "threeheavens.test"

def cloudflare(client_ip, supplied = {})
  supplied = supplied.dup
  spoofed_forwarded_for = supplied.delete("X-Forwarded-For")
  supplied.delete("CF-Connecting-IP")
  supplied.merge(
    "Host" => APP_HOST,
    "X-Forwarded-For" => [ spoofed_forwarded_for, client_ip ].compact.join(", "),
    "CF-Connecting-IP" => client_ip,
    "X-Forwarded-Proto" => "https"
  )
end

def http = Net::HTTP.new(PROXY, 80).tap { |connection| connection.read_timeout = 30 }

def ip(offset) = "198.51.100.#{BASE_OCTET + offset}"

SPOOF = lambda do |value|
  { "X-Forwarded-For" => value, "Client-Ip" => value, "True-Client-IP" => value, "CF-Connecting-IP" => value }
end

def echo(client_ip, supplied = {})
  response = http.request(Net::HTTP::Get.new("/probe", cloudflare(client_ip, supplied)))
  JSON.parse(response.body)
end

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
  Array.new(count) { |index| failed_sign_in(client_ip, "probe-#{MODE}-#{label}-#{index}@example.test", supplied ? supplied.call(index) : {}) }
end

case PHASE
when "echo"
  require "bundler/setup"
  require "action_dispatch"
  require "/rails/app/middleware/client_ip_header_filter"
  rails = ClientIpHeaderFilter.new(ActionDispatch::RemoteIp.new(->(env) { [ 200, {}, [ ActionDispatch::Request.new(env).remote_ip ] ] }, true, nil))
  cases = {
    "plain client #{ip(1)}" => [ ip(1), {} ],
    "client #{ip(1)} spoofing 203.0.113.9 in every IP header" => [ ip(1), SPOOF.call("203.0.113.9") ],
    "client #{ip(1)} spoofing private/loopback chain" => [ ip(1), SPOOF.call("10.0.0.1, 127.0.0.1, 172.18.0.2") ],
    "client #{ip(1)} spoofing victim #{ip(2)}" => [ ip(1), SPOOF.call(ip(2)) ]
  }
  cases.each do |label, (client_ip, supplied)|
    seen = echo(client_ip, supplied)
    env = { "REMOTE_ADDR" => seen["remote_addr"], "HTTP_X_FORWARDED_FOR" => seen.dig("headers", "x-forwarded-for") }
    env["HTTP_CLIENT_IP"] = seen.dig("headers", "client-ip") if seen.dig("headers", "client-ip")
    remote_ip = begin
      rails.call(env).last.first
    rescue ActionDispatch::RemoteIp::IpSpoofAttackError => error
      "IpSpoofAttackError: #{error.message}"
    end
    puts JSON.generate("mode" => MODE, "case" => label, "at_puma" => seen, "rails_remote_ip" => remote_ip)
  end
when "app"
  result = { "mode" => MODE }
  result["S1 client A: 11 failed sign-ins"] = attempts(11, ip(1), "a")
  result["S1 client B (distinct): 1 failed sign-in after A is throttled"] = attempts(1, ip(2), "b")
  result["S2 client C: 11 attempts rotating spoofed XFF/Client-Ip/True-Client-IP/CF-Connecting-IP"] =
    attempts(11, ip(3), "c") { |index| SPOOF.call("203.0.113.#{index + 1}") }
  result["S3 attacker D: 11 attempts claiming victim E's address, then private/loopback"] =
    attempts(11, ip(4), "d") { |index| SPOOF.call(index.even? ? ip(5) : "10.0.0.1, 127.0.0.1") }
  result["S3 victim E: 1 failed sign-in after D's flood"] = attempts(1, ip(5), "e")
  puts JSON.pretty_generate(result)
end
