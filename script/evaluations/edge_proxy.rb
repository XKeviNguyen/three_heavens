# Evaluation: the production edge (kamal-proxy, as config/deploy.yml renders
# it) versus Traefik v3 in front of the same image (Thruster -> Puma ->
# Rails), on one machine. It measures behaviour the deployment depends on and
# writes JSON. It is a local test bench only: nothing here is production
# configuration, and the Traefik settings exist only inside this script.
#
# Usage, from the repository root with the compose PostgreSQL running and an
# image built from this checkout:
#   IMAGE=three-heavens:breaker bin/rails runner script/evaluations/edge_proxy.rb tmp/edge_proxy.json
#
# TLS uses a throwaway local CA for the name app.test; the client verifies
# against that CA. Databases are disposable (three_heavens_edge_*) and are
# dropped at the end, as are every container, network-scoped name and file
# this script creates.
require "json"
require "net/http"
require "open3"
require "openssl"
require "securerandom"
require "socket"
require "tmpdir"

OUTPUT = ARGV.fetch(0)
IMAGE = ENV.fetch("IMAGE")
NETWORK = "three_heavens_default"
DATABASE_HOST = "three-heavens-postgres"
APP_HOST = "app.test"
KAMAL_PROXY_IMAGE = "basecamp/kamal-proxy:v0.9.2"
TRAEFIK_IMAGE = "traefik:v3.5"
MAX_REQUEST_BODY = 22_020_096
MIB = 1024 * 1024
DATABASES = %w[primary cache queue cable].to_h { |role| [ role, "three_heavens_edge_#{role}" ] }
PROXIES = {
  "kamal-proxy" => { http: 8080, https: 8443, container: "edge-kamal-proxy" },
  "traefik" => { http: 9080, https: 9443, container: "edge-traefik" }
}.freeze

def log(message) = $stderr.puts("[edge] #{message}")
def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def docker(*arguments) = Open3.capture2e("docker", *arguments).tap { |output, status| raise "docker #{arguments.first(2).join(' ')}: #{output.lines.last}" unless status.success? }.first
def development_config = ActiveRecord::Base.configurations.configs_for(env_name: "development", name: "primary").configuration_hash

def database_urls
  config = development_config
  user = ERB::Util.url_encode(config.fetch(:username).to_s)
  password = ERB::Util.url_encode(config.fetch(:password).to_s)
  DATABASES.to_h do |role, name|
    [ role == "primary" ? "DATABASE_URL" : "#{role.upcase}_DATABASE_URL", "postgres://#{user}:#{password}@#{DATABASE_HOST}:5432/#{name}" ]
  end
end

def drop_databases
  ActiveRecord::Base.establish_connection(development_config.merge(database: "postgres"))
  DATABASES.each_value do |name|
    raise "refusing to drop #{name}" unless name.start_with?("three_heavens_edge_")

    ActiveRecord::Base.connection.execute("DROP DATABASE IF EXISTS #{ActiveRecord::Base.connection.quote_table_name(name)} WITH (FORCE)")
  end
ensure
  ActiveRecord::Base.establish_connection(:primary)
end

# A local CA and a certificate for APP_HOST signed by it.
def write_certificates(directory)
  ca_key = OpenSSL::PKey::EC.generate("prime256v1")
  ca = OpenSSL::X509::Certificate.new
  ca.version = 2
  ca.serial = 1
  ca.subject = ca.issuer = OpenSSL::X509::Name.parse("/CN=Three Heavens edge evaluation CA")
  ca.public_key = ca_key
  ca.not_before = Time.now - 60
  ca.not_after = Time.now + 86_400
  extensions = OpenSSL::X509::ExtensionFactory.new(ca, ca)
  ca.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
  ca.add_extension(extensions.create_extension("keyUsage", "keyCertSign,cRLSign", true))
  ca.sign(ca_key, OpenSSL::Digest.new("SHA256"))

  key = OpenSSL::PKey::EC.generate("prime256v1")
  certificate = OpenSSL::X509::Certificate.new
  certificate.version = 2
  certificate.serial = 2
  certificate.subject = OpenSSL::X509::Name.parse("/CN=#{APP_HOST}")
  certificate.issuer = ca.subject
  certificate.public_key = key
  certificate.not_before = Time.now - 60
  certificate.not_after = Time.now + 86_400
  extensions = OpenSSL::X509::ExtensionFactory.new(certificate, ca)
  certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:#{APP_HOST}"))
  certificate.add_extension(extensions.create_extension("extendedKeyUsage", "serverAuth"))
  certificate.sign(ca_key, OpenSSL::Digest.new("SHA256"))

  File.write(File.join(directory, "ca.pem"), ca.to_pem)
  File.write(File.join(directory, "cert.pem"), certificate.to_pem)
  File.write(File.join(directory, "key.pem"), key.to_pem)
  File.chmod(0o644, *%w[ca.pem cert.pem key.pem].map { |name| File.join(directory, name) })
end

def start_app(name)
  environment = database_urls.merge(
    "APP_HOST" => APP_HOST, "SECRET_KEY_BASE" => SecureRandom.hex(64),
    "MAIL_FROM" => "edge@example.invalid", "SMTP_HOST" => "smtp.example.invalid",
    "SMTP_USERNAME" => "unused", "SMTP_PASSWORD" => "unused", "SOLID_QUEUE_IN_PUMA" => "true", "RAILS_LOG_LEVEL" => "warn"
  )
  command = [ "docker", "run", "-d", "--name", name, "--network", NETWORK, "--memory", "768m", "--memory-swap", "768m" ]
  environment.each_key { |key| command.push("-e", key) }
  _, status = Open3.capture2e(environment, *command, IMAGE)
  raise "could not start #{name}" unless status.success?

  deadline = monotonic + 120
  until docker_exec_ok?(name, "curl -fsS http://127.0.0.1:80/up")
    raise "#{name} did not become healthy" if monotonic > deadline

    sleep 0.5
  end
end

def docker_exec_ok?(name, command) = Open3.capture2e("docker", "exec", name, "sh", "-c", command).last.success?

def start_kamal_proxy(certificates)
  proxy = PROXIES.fetch("kamal-proxy")
  docker("run", "-d", "--name", proxy[:container], "--network", NETWORK,
         "-p", "127.0.0.1:#{proxy[:http]}:80", "-p", "127.0.0.1:#{proxy[:https]}:443",
         "-v", "#{certificates}:/certs:ro", KAMAL_PROXY_IMAGE)
  sleep 1
  kamal_proxy_deploy("edge-app")
end

# The options Kamal renders from config/deploy.yml (ssl, buffering with
# max_request_body, /up health check), with the local certificate.
def kamal_proxy_deploy(target)
  docker("exec", PROXIES.dig("kamal-proxy", :container), "kamal-proxy", "deploy", "three_heavens",
         "--target=#{target}:80", "--host=#{APP_HOST}", "--tls", "--tls-certificate-path=/certs/cert.pem",
         "--tls-private-key-path=/certs/key.pem", "--health-check-path=/up", "--buffer-requests", "--buffer-responses",
         "--max-request-body=#{MAX_REQUEST_BODY}")
end

TRAEFIK_STATIC = <<~YAML
  entryPoints:
    web:
      address: ":80"
      http:
        redirections:
          entryPoint: { to: websecure, scheme: https }
    websecure:
      address: ":443"
  providers:
    file:
      directory: /etc/traefik/dynamic
      watch: true
  log:
    level: ERROR
YAML

def traefik_dynamic(target) = <<~YAML
  http:
    routers:
      three-heavens:
        rule: Host(`#{APP_HOST}`)
        entryPoints: [ websecure ]
        service: three-heavens
        middlewares: [ request-limit ]
        tls: {}
    middlewares:
      request-limit:
        buffering:
          maxRequestBodyBytes: #{MAX_REQUEST_BODY}
    services:
      three-heavens:
        loadBalancer:
          healthCheck: { path: /up, interval: 2s, timeout: 2s }
          servers:
            - url: http://#{target}:80
  tls:
    certificates:
      - certFile: /certs/cert.pem
        keyFile: /certs/key.pem
YAML

def start_traefik(certificates, configuration)
  proxy = PROXIES.fetch("traefik")
  File.write(File.join(configuration, "traefik.yml"), TRAEFIK_STATIC)
  FileUtils.mkdir_p(File.join(configuration, "dynamic"))
  write_traefik_target(configuration, "edge-app")
  docker("run", "-d", "--name", proxy[:container], "--network", NETWORK,
         "-p", "127.0.0.1:#{proxy[:http]}:80", "-p", "127.0.0.1:#{proxy[:https]}:443",
         "-v", "#{certificates}:/certs:ro", "-v", "#{configuration}/traefik.yml:/etc/traefik/traefik.yml:ro",
         "-v", "#{configuration}/dynamic:/etc/traefik/dynamic:ro", TRAEFIK_IMAGE)
  sleep 3
end

def write_traefik_target(configuration, target)
  path = File.join(configuration, "dynamic", "three_heavens.yml")
  File.write("#{path}.tmp", traefik_dynamic(target))
  File.rename("#{path}.tmp", path)
end

# HTTPS client that verifies the server against the local CA.
class EdgeClient
  def initialize(port, ca_file)
    @port = port
    @ca_file = ca_file
  end

  def request(message, read_timeout: 30)
    message["Host"] = APP_HOST
    http = Net::HTTP.new(APP_HOST, @port)
    http.ipaddr = "127.0.0.1"
    http.use_ssl = true
    http.ca_file = @ca_file
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER
    http.read_timeout = read_timeout
    http.start { |connection| connection.request(message) }
  end

  def get(path, headers = {}) = request(Net::HTTP::Get.new(path, headers))
end

def raw_http(port, request)
  socket = TCPSocket.new("127.0.0.1", port)
  socket.write(request)
  socket.read(64).to_s[%r{\AHTTP/1\.1 (\d+)}, 1]
ensure
  socket&.close
end

def failed_sign_in(client, forwarded_for, email)
  page = client.get("/login")
  cookie = page.get_fields("set-cookie").map { |value| value.split(";").first }.join("; ")
  token = page.body[/name="csrf-token" content="([^"]+)"/, 1]
  post = Net::HTTP::Post.new("/session", "Cookie" => cookie, "X-Forwarded-For" => forwarded_for)
  post.set_form_data("authenticity_token" => token, "session[email]" => email, "session[password]" => "wrong password value")
  client.request(post).code
end

def tls_socket(port, ca_file)
  context = OpenSSL::SSL::SSLContext.new
  context.set_params(ca_file:, verify_mode: OpenSSL::SSL::VERIFY_PEER)
  socket = OpenSSL::SSL::SSLSocket.new(TCPSocket.new("127.0.0.1", port), context)
  socket.hostname = APP_HOST
  socket.sync_close = true
  socket.connect
  socket.post_connection_check(APP_HOST)
  socket
end

# TLS control records can make the socket readable before any response, so
# the read itself is what times out.
def response_status(socket, timeout: 30)
  socket.to_io.timeout = timeout
  socket.readpartial(64)[%r{\AHTTP/1\.1 (\d+)}, 1] || "unparsed"
rescue IO::TimeoutError
  "no response in #{timeout} s"
rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
  "reset"
end

# A TLS connection that sends a body as chunked transfer encoding (with
# invalid chunk sizes after the first few chunks when malformed).
def chunked_post(port, ca_file, path, bytes, chunk, malformed: false)
  socket = tls_socket(port, ca_file)
  socket.write("POST #{path} HTTP/1.1\r\nHost: #{APP_HOST}\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n")
  piece = "x" * chunk
  sent = 0
  begin
    while sent < bytes
      socket.write(malformed && sent >= chunk * 4 ? "zz\r\n#{piece}\r\n" : "#{chunk.to_s(16)}\r\n#{piece}\r\n")
      sent += chunk
    end
    socket.write("0\r\n\r\n")
  rescue SystemCallError, IOError, OpenSSL::SSL::SSLError
    nil
  end
  response_status(socket)
ensure
  socket&.close
end

# Declares a body over the proxy limit and sends none of it.
def declared_oversize(port, ca_file)
  socket = tls_socket(port, ca_file)
  socket.write("POST /source_imports HTTP/1.1\r\nHost: #{APP_HOST}\r\nContent-Type: application/octet-stream\r\nContent-Length: #{MAX_REQUEST_BODY + 1}\r\nConnection: close\r\n\r\n")
  response_status(socket)
ensure
  socket&.close
end

def multipart_upload(client, files)
  boundary = "EdgeBoundary#{SecureRandom.hex(4)}"
  body = +""
  files.each_with_index do |bytes, index|
    body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"translation_reference[source_file_#{index}]\"; filename=\"f#{index}.txt\"\r\nContent-Type: text/plain\r\n\r\n#{bytes}\r\n"
  end
  body << "--#{boundary}--\r\n"
  post = Net::HTTP::Post.new("/translation_references", "Content-Type" => "multipart/form-data; boundary=#{boundary}")
  post.body = body
  [ body.bytesize, client.request(post).code ]
end

def container_memory_mib(name)
  usage = docker("stats", "--no-stream", "--format", "{{.MemUsage}}", name).split("/").first.strip
  value = usage.to_f
  usage.end_with?("GiB") ? (value * 1024).round(1) : usage.end_with?("KiB") ? (value / 1024).round(1) : value.round(1)
end

def container_cpu_seconds(name)
  id = docker("inspect", "--format", "{{.Id}}", name).strip
  path = [ "/sys/fs/cgroup/cpu,cpuacct/docker/#{id}/cpuacct.usage", "/sys/fs/cgroup/cpuacct/docker/#{id}/cpuacct.usage" ].find { |candidate| File.exist?(candidate) }
  path ? (File.read(path).to_i / 1e9).round(2) : nil
end

def evaluate(name, proxy, ca_file)
  client = EdgeClient.new(proxy[:https], ca_file)
  result = { name: }
  result[:http_redirect] = raw_http(proxy[:http], "GET /login HTTP/1.1\r\nHost: #{APP_HOST}\r\nConnection: close\r\n\r\n")
  result[:health] = { up: client.get("/up").code, ready: client.get("/ready").code, login: client.get("/login").code }

  # Client-chosen X-Forwarded-For must not choose the rate-limit address:
  # 11 failed sign-ins for different accounts, each claiming a new address.
  codes = Array.new(11) { |index| failed_sign_in(client, "203.0.113.#{index + 1}", "nobody-#{name}-#{index}@example.invalid") }
  result[:spoofed_forwarded_for] = { codes: codes.tally, throttled: codes.last == "429" }
  result[:client_ip_mismatch] = client.get("/login", "Client-Ip" => "198.51.100.9", "X-Forwarded-For" => "203.0.113.200").code

  result[:declared_oversize] = declared_oversize(proxy[:https], ca_file)
  started = monotonic
  result[:chunked_30mib] = chunked_post(proxy[:https], ca_file, "/source_imports", 30 * MIB, 64 * 1024)
  result[:chunked_30mib_seconds] = (monotonic - started).round(2)
  result[:chunked_30mib_1kib_chunks] = chunked_post(proxy[:https], ca_file, "/source_imports", 30 * MIB, 1024)
  result[:malformed_chunks] = chunked_post(proxy[:https], ca_file, "/source_imports", MIB, 1024, malformed: true)
  # Signed out and without a CSRF token, so the application answers 422;
  # what matters is that the proxy passed the body on.
  bytes, code = multipart_upload(client, [ "a" * (10 * MIB - 1024), "b" * (10 * MIB - 1024) ])
  result[:two_10mib_uploads] = { bytes:, code:, reached_application: code != "413" }

  # 150 clients that send headers one byte a second while /login is probed.
  slow = Array.new(150) do
    Thread.new do
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(ca_file:, verify_mode: OpenSSL::SSL::VERIFY_PEER)
      socket = OpenSSL::SSL::SSLSocket.new(TCPSocket.new("127.0.0.1", proxy[:https]), context)
      socket.hostname = APP_HOST
      socket.connect
      "GET /login HTTP/1.1\r\nHost: #{APP_HOST}\r\nX-Slow: ".each_char { |character| socket.write(character); sleep 1 }
    rescue StandardError
      nil
    ensure
      socket&.close
    end
  end
  probe_times = Array.new(10) do
    sleep 1
    started = monotonic
    [ (client.get("/login").code rescue "down"), (monotonic - started).round(3) ]
  end
  slow.each(&:kill)
  result[:slow_clients_login_probes] = { codes: probe_times.map(&:first).tally, slowest_seconds: probe_times.map(&:last).max }

  memory_idle = container_memory_mib(proxy[:container])
  cpu_before = container_cpu_seconds(proxy[:container])
  flood = Array.new(40) { Thread.new { chunked_post(proxy[:https], ca_file, "/translation_workspace_draft", 30 * MIB, 64 * 1024) } }
  peak = memory_idle
  sampling = true
  sampler = Thread.new { (peak = [ peak, container_memory_mib(proxy[:container]) ].max) while sampling }
  flood_codes = flood.map(&:value).tally
  sampling = false
  sampler.join
  result[:resources] = { idle_mib: memory_idle, peak_mib_during_40x30mib: peak, flood_codes:, cpu_seconds_for_flood: (cpu_before && (container_cpu_seconds(proxy[:container]) - cpu_before).round(2)) }
  result
end

def wait_healthy(name)
  deadline = monotonic + 120
  sleep 0.5 until docker_exec_ok?(name, "curl -fsS http://127.0.0.1:80/up") || monotonic > deadline
end

def switch_to(name, target, configuration)
  if name == "kamal-proxy"
    kamal_proxy_deploy(target) # waits for the target's health check, then drains the old one
  else
    write_traefik_target(configuration, target)
    sleep 3 # the file provider reloads on change; no drain step exists to wait for
  end
end

# A deploy and a rollback under steady requests, as an operator would run
# them: start the new container, switch the proxy to it, stop the old one;
# then start the old one again, switch back, and stop the new one.
def deploy_and_rollback(name, proxy, ca_file, configuration)
  client = EdgeClient.new(proxy[:https], ca_file)
  docker("start", "edge-app-2")
  wait_healthy("edge-app-2")
  outcomes = []
  running = true
  load = Thread.new do
    while running
      outcomes << (client.get("/login").code rescue "error")
      sleep 0.05
    end
  end
  sleep 2
  timings = []
  [ %w[edge-app-2 edge-app], %w[edge-app edge-app-2] ].each do |new_target, old_target|
    if new_target == "edge-app"
      docker("start", new_target)
      wait_healthy(new_target)
    end
    started = monotonic
    switch_to(name, new_target, configuration)
    timings << (monotonic - started).round(2)
    docker("stop", old_target)
    sleep 2
  end
  running = false
  load.join
  { requests: outcomes.size, non_200: outcomes.reject { |code| code == "200" }.tally, switch_seconds: timings }
end

result = { image: IMAGE, kamal_proxy: KAMAL_PROXY_IMAGE, traefik: TRAEFIK_IMAGE, proxies: [] }
containers = %w[edge-app edge-app-2] + PROXIES.values.map { |proxy| proxy[:container] }
Dir.mktmpdir("three-heavens-edge-") do |directory|
  certificates = File.join(directory, "certs")
  configuration = File.join(directory, "traefik")
  FileUtils.mkdir_p([ certificates, configuration ])
  File.chmod(0o755, directory, certificates, configuration)
  write_certificates(certificates)
  ca_file = File.join(certificates, "ca.pem")
  begin
    drop_databases
    log "starting the application"
    start_app("edge-app")
    start_kamal_proxy(certificates)
    start_traefik(certificates, configuration)
    PROXIES.each do |name, proxy|
      log "evaluating #{name}"
      result[:proxies] << evaluate(name, proxy, ca_file)
      log result[:proxies].last.to_json
    end
    start_app("edge-app-2")
    docker("stop", "edge-app-2")
    result[:deploy_and_rollback] = PROXIES.to_h do |name, proxy|
      log "deploying and rolling back behind #{name}"
      [ name, deploy_and_rollback(name, proxy, ca_file, configuration) ]
    end
    log result[:deploy_and_rollback].to_json
  rescue StandardError => error
    result[:error] = "#{error.class}: #{error.message}"
    log result[:error]
  ensure
    containers.each { |name| system("docker", "rm", "-f", name, out: File::NULL, err: File::NULL) }
    drop_databases
    File.write(OUTPUT, JSON.pretty_generate(result))
    log "wrote #{OUTPUT}"
  end
end
