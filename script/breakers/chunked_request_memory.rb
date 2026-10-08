# Breaker: many simultaneous large request bodies against the production
# image under a 768 MiB no-swap memory limit. The web process must survive,
# reject every oversized body, and return to its idle footprint.
#
# Each request body Puma reads costs kernel socket buffers, freed allocator
# memory, and tempfile pages, so many at once could exhaust a small
# container. config/deploy.yml caps the container's socket buffers and the
# Dockerfile makes jemalloc return freed memory at once; this script shows
# what those controls hold under load. See docs/operations/production-deploy.md.
#
# Usage, from the repository root with the compose PostgreSQL running:
#   docker build --network host -t three-heavens:breaker .
#   IMAGE=three-heavens:breaker bin/rails runner script/breakers/chunked_request_memory.rb tmp/chunked_request_memory.json
#
# The "pdf" scenarios add signed-in PDF uploads that each hold the single
# PDF worker slot for the full parse limit (and some that inflate to 1 GiB,
# driving the worker to its address-space limit) while hostile chunked
# bodies arrive and /login is probed. They create disposable verified
# accounts in the breaker database (several, since each account may upload
# only SourceImports::Limits::UPLOADS_PER_WINDOW files per window) and then
# check that a normal PDF still imports, i.e. no worker slot leaked.
#
# Optional environment:
#   SCENARIOS  comma-separated keys from SCENARIOS below, or wavesN (default: all)
#   SYSCTLS    "name=value;..." (default: the sysctls in config/deploy.yml;
#              "none" runs without them)
#   EXTRA_ENV  "NAME=value;..." for the container, e.g. "MALLOC_CONF=" to run
#              with jemalloc's default page retention
#
# It needs Docker and the development database server. Connection details
# come from this process's database configuration and reach the container
# only through its environment; nothing is printed. The container runs on the
# compose network (as Kamal runs the app on its own network, where these
# sysctls apply), publishes its ports on 127.0.0.1 only, and uses disposable
# databases named three_heavens_breaker_*, which are dropped at the end.
require "json"
require "net/http"
require "open3"
require "securerandom"
require "socket"
require Rails.root.join("test/support/document_io_test_helper").to_s

# Builds the synthetic PDFs (pdf_with_text, inflating_pdf, build_pdf).
extend DocumentIoTestHelper

OUTPUT = ARGV.fetch(0)
IMAGE = ENV.fetch("IMAGE")
MEMORY_LIMIT = "768m"
HTTP_PORT = 3900
PUMA_PORT = 3901
NETWORK = "three_heavens_default"
DATABASE_HOST = "three-heavens-postgres"
DATABASES = %w[primary cache queue cable].to_h { |role| [ role, "three_heavens_breaker_#{role}" ] }
MIB = 1024 * 1024
DEPLOY_SYSCTLS = Rails.root.join("config/deploy.yml").read.scan(/^\s*-\s*(net\.\S+=.+)$/).flatten.map(&:strip)
SYSCTLS = case ENV["SYSCTLS"]
when nil then DEPLOY_SYSCTLS
when "none" then []
else ENV["SYSCTLS"].split(";").reject(&:empty?)
end
EXTRA_ENV = ENV.fetch("EXTRA_ENV", "").split(";").reject(&:empty?).to_h { |pair| pair.split("=", 2).then { |k, v| [ k, v.to_s ] } }

SCENARIOS = {
  "c1" => { label: "1 chunked 30 MiB", n: 1, bytes: 30 * MIB, chunk: 1024, mode: :chunked },
  "c5" => { label: "5 chunked 30 MiB", n: 5, bytes: 30 * MIB, chunk: 1024, mode: :chunked },
  "c20" => { label: "20 chunked 30 MiB", n: 20, bytes: 30 * MIB, chunk: 1024, mode: :chunked },
  "c80" => { label: "80 chunked 30 MiB, 1 KiB chunks", n: 80, bytes: 30 * MIB, chunk: 1024, mode: :chunked },
  "c80big" => { label: "80 chunked 30 MiB, 64 KiB chunks", n: 80, bytes: 30 * MIB, chunk: 65_536, mode: :chunked },
  "l80" => { label: "80 Content-Length 20 MiB", n: 80, bytes: 20 * MIB, chunk: 65_536, mode: :length },
  "legit" => { label: "80 chunked 30 MiB with /login probes", n: 80, bytes: 30 * MIB, chunk: 65_536, mode: :chunked, probe: true },
  "slow" => { label: "40 slow chunked senders with /login probes", n: 40, bytes: 256 * 1024, chunk: 1024, mode: :chunked, delay: 0.05, probe: true },
  "disconnect" => { label: "80 chunked, client disconnects mid-body", n: 80, bytes: 30 * MIB, chunk: 1024, mode: :disconnect },
  "malformed" => { label: "80 malformed chunk framing", n: 80, bytes: 30 * MIB, chunk: 1024, mode: :malformed },
  "c200" => { label: "200 chunked 30 MiB, 64 KiB chunks", n: 200, bytes: 30 * MIB, chunk: 65_536, mode: :chunked },
  "pdf" => { label: "PDF slot held for 30 s with /login probes", n: 0, bytes: 0, chunk: 1, mode: :chunked, probe: true, pdf: 30 },
  "pdf_chunked" => { label: "80 chunked 30 MiB during 30 s of hostile PDFs, with /login probes", n: 80, bytes: 30 * MIB, chunk: 65_536,
                     mode: :chunked, probe: true, pdf: 30 }
}.freeze
PDF_ACCOUNTS = 24
PDF_SENDERS = 3
PDF_PASSWORD = "breaker #{SecureRandom.hex(12)}".freeze

def log(message) = $stderr.puts("[breaker] #{message}")
def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
    raise "refusing to drop #{name}" unless name.start_with?("three_heavens_breaker_")

    ActiveRecord::Base.connection.execute("DROP DATABASE IF EXISTS #{ActiveRecord::Base.connection.quote_table_name(name)} WITH (FORCE)")
  end
ensure
  ActiveRecord::Base.establish_connection(:primary)
end

def start_container
  name = "th-breaker-#{SecureRandom.hex(3)}"
  environment = database_urls.merge(
    "APP_HOST" => "localhost", "SECRET_KEY_BASE" => SecureRandom.hex(64),
    "MAIL_FROM" => "breaker@example.invalid", "SMTP_HOST" => "smtp.example.invalid",
    "SMTP_USERNAME" => "unused", "SMTP_PASSWORD" => "unused", "SOLID_QUEUE_IN_PUMA" => "true",
    "HTTP_PORT" => HTTP_PORT.to_s, "TARGET_PORT" => PUMA_PORT.to_s, "RAILS_LOG_LEVEL" => "warn"
  ).merge(EXTRA_ENV)
  command = [ "docker", "run", "-d", "--name", name, "--memory", MEMORY_LIMIT, "--memory-swap", MEMORY_LIMIT,
              "--network", NETWORK, "-p", "127.0.0.1:#{HTTP_PORT}:#{HTTP_PORT}" ]
  SYSCTLS.each { |sysctl| command.push("--sysctl", sysctl) }
  environment.each_key { |key| command.push("-e", key) }
  id, status = Open3.capture2(environment, *command, IMAGE)
  raise "docker run failed" unless status.success?

  [ name, id.strip ]
end

# cgroup v2 (systemd or cgroupfs driver), else the cgroup v1 memory
# controller. Under v1 kernel socket buffers are reported (memory.kmem.tcp,
# whose accounting the script enables) but not charged to the container's
# limit as v2 charges them, so v1 limits are less strict than production.
def cgroup(id)
  [ "/sys/fs/cgroup/system.slice/docker-#{id}.scope", "/sys/fs/cgroup/docker/#{id}", "/sys/fs/cgroup/memory/docker/#{id}" ]
    .find { |path| File.directory?(path) } or raise "no cgroup found for the container"
end

def cgroup_v1?(id) = File.exist?("#{cgroup(id)}/memory.usage_in_bytes")

def memory(id)
  stat = File.read("#{cgroup(id)}/memory.stat")
  mib = ->(key) { (stat[/^#{key} (\d+)/, 1].to_i.to_f / MIB).round(1) }
  if cgroup_v1?(id)
    sock = (File.read("#{cgroup(id)}/memory.kmem.tcp.usage_in_bytes").to_i.to_f / MIB).round(1)
    current = (File.read("#{cgroup(id)}/memory.usage_in_bytes").to_i.to_f / MIB).round(1)
    { current:, current_with_sock: (current + sock).round(1), anon: mib["total_rss"], sock:, dirty: mib["total_dirty"] }
  else
    { current: (File.read("#{cgroup(id)}/memory.current").to_i.to_f / MIB).round(1), anon: mib["anon"], sock: mib["sock"], dirty: mib["file_dirty"] }
  end
end

def oom_kills(id)
  events = cgroup_v1?(id) ? "memory.oom_control" : "memory.events"
  File.read("#{cgroup(id)}/#{events}")[/^oom_kill (\d+)/, 1].to_i
end

def enable_socket_accounting(id)
  File.write("#{cgroup(id)}/memory.kmem.tcp.limit_in_bytes", (8 * 1024 * MIB).to_s) if cgroup_v1?(id)
rescue SystemCallError
  nil
end

def puma(id)
  File.read("#{cgroup(id)}/cgroup.procs").split.map(&:to_i).filter_map do |pid|
    next unless File.read("/proc/#{pid}/cmdline").start_with?("puma")

    status = File.read("/proc/#{pid}/status")
    fds = Dir.glob("/proc/#{pid}/fd/*")
    { pid:, anon: (status[/^RssAnon:\s+(\d+)/, 1].to_i / 1024.0).round(1), threads: status[/^Threads:\s+(\d+)/, 1].to_i,
      fds: fds.size, deleted_files: fds.count { |fd| File.readlink(fd).end_with?("(deleted)") rescue false } }
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end.first
end

def get(path)
  socket = TCPSocket.new("127.0.0.1", HTTP_PORT)
  socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  socket.read(64).to_s[%r{\AHTTP/1\.1 (\d+)}, 1].tap { socket.close }
rescue SystemCallError, IOError
  "down"
end

# One raw HTTP/1.1 request; returns the response status or how it ended.
def send_body(bytes:, chunk:, mode:, delay: 0)
  socket = TCPSocket.new("127.0.0.1", HTTP_PORT)
  framing = mode == :length ? "Content-Length: #{bytes}" : "Transfer-Encoding: chunked"
  socket.write("POST /translation_workspace_draft HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nConnection: close\r\n#{framing}\r\n\r\n")
  piece = "x" * chunk
  sent = 0
  begin
    while sent < bytes
      if mode == :length then socket.write(piece)
      elsif mode == :malformed && sent >= chunk * 4 then socket.write("zz\r\n#{piece}\r\n")
      else socket.write("#{chunk.to_s(16)}\r\n#{piece}\r\n")
      end
      sent += chunk
      return "disconnected".tap { socket.close } if mode == :disconnect && sent >= bytes / 2

      sleep(delay) if delay.positive?
    end
    socket.write("0\r\n\r\n") unless mode == :length
  rescue SystemCallError, IOError
    # The server stopped reading the body; its response says why.
  end
  IO.select([ socket ], nil, nil, 60)
  (socket.readpartial(256)[%r{\AHTTP/1\.1 (\d+)}, 1] rescue nil) || "reset"
ensure
  socket&.close
end

# PDF workers (fresh Ruby interpreters, not Puma) running in the container.
def pdf_workers(id)
  File.read("#{cgroup(id)}/cgroup.procs").split.count do |pid|
    File.read("/proc/#{pid}/cmdline").include?("PdfExtractor::Worker")
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end
end

def create_pdf_accounts(name)
  emails = Array.new(PDF_ACCOUNTS) { |index| "breaker-#{index}-#{SecureRandom.hex(4)}@example.invalid" }
  script = "#{emails.inspect}.each { |email| User.create!(email:, password: ENV.fetch('BREAKER_PASSWORD'), role: :user, status: :active, " \
    "email_verified_at: Time.current, locale: 'en', managed_ai_access: false) }"
  _, status = Open3.capture2e({ "BREAKER_PASSWORD" => PDF_PASSWORD }, "docker", "exec", "-e", "BREAKER_PASSWORD", name, "bin/rails", "runner", script)
  raise "could not create breaker accounts" unless status.success?

  emails
end

# A signed-in browser: its cookies and the page's authenticity token. Each
# account signs in from its own documentation address (forwarded through
# Thruster as a real client's would be), so the per-network sign-in limit
# applies to each separately.
class BreakerSession
  def initialize(email, address)
    @cookies = {}
    @address = address
    token = csrf_token(request(Net::HTTP::Get.new("/login")))
    response = request(form(Net::HTTP::Post.new("/session"), "authenticity_token" => token, "session[email]" => email, "session[password]" => PDF_PASSWORD))
    raise "breaker sign-in failed (#{response.code})" unless response.code == "302"

    @token = csrf_token(request(Net::HTTP::Get.new("/source_imports/new")))
  end

  # Returns the HTTP status of one PDF import.
  def import(pdf)
    post = Net::HTTP::Post.new("/source_imports")
    post["Accept"] = "application/json"
    post["X-CSRF-Token"] = @token
    post.set_form([ [ "source_import[request_key]", SecureRandom.hex(16) ],
                    [ "source_import[source_file]", StringIO.new(pdf), { filename: "source.pdf", content_type: "application/pdf" } ] ],
                  "multipart/form-data")
    request(post).code
  rescue SystemCallError, IOError, Net::ReadTimeout
    "down"
  end

  private

  def form(post, fields) = post.tap { post.set_form_data(fields) }

  def csrf_token(response) = response.body.to_s[/name="csrf-token" content="([^"]+)"/, 1] || raise("no CSRF token")

  def request(message)
    message["Host"] = "localhost"
    message["X-Forwarded-For"] = @address
    message["Cookie"] = @cookies.map { |key, value| "#{key}=#{value}" }.join("; ")
    response = Net::HTTP.start("127.0.0.1", HTTP_PORT, read_timeout: 60) { |http| http.request(message) }
    Array(response.get_fields("set-cookie")).each { |cookie| key, value = cookie.split(";").first.split("=", 2); @cookies[key] = value }
    response
  end
end

def pdf_attack(sessions, seconds)
  hostile = [ build_pdf([ { content: Zlib::Deflate.deflate("q Q " * 6_000_000), filter: "/FlateDecode" } ]), inflating_pdf(1024 * MIB) ]
  deadline = monotonic + seconds
  Array.new(PDF_SENDERS) do |sender|
    Thread.new do
      statuses = Hash.new(0)
      turn = sender
      while monotonic < deadline
        statuses[sessions[turn % sessions.size].import(hostile[turn % hostile.size])] += 1
        turn += PDF_SENDERS
      end
      statuses
    end
  end
end

def run_scenario(id, label:, n:, probe: false, pdf: nil, **request)
  kills_before = oom_kills(id)
  pid_before = puma(id)&.dig(:pid)
  peaks = Hash.new(0.0)
  running = true
  sampler = Thread.new do
    while running
      memory(id).each { |key, value| peaks[key] = [ peaks[key], value ].max } rescue nil
      peaks[:puma_anon] = [ peaks[:puma_anon], puma(id)&.dig(:anon).to_f ].max
      sleep 0.02
    end
  end
  probes = []
  prober = probe && Thread.new do
    while running
      started = monotonic
      probes << [ get("/login"), (monotonic - started).round(3) ]
      sleep 0.2
    end
  end
  attackers = pdf && pdf_attack(@pdf_sessions, pdf)
  sleep 3 if attackers
  gate = Queue.new
  senders = Array.new(n) { Thread.new { gate.pop; send_body(**request) } }
  sleep 0.2
  n.times { gate << true }
  statuses = senders.map(&:value).tally
  pdf_statuses = attackers&.map(&:value)&.reduce { |a, b| a.merge(b) { |_, x, y| x + y } }
  sleep 2
  running = false
  sampler.join
  prober.join if prober
  after = puma(id)
  {
    label:, statuses:, peak_mib: peaks.transform_values { |value| value.round(1) },
    oom_kills: oom_kills(id) - kills_before, up_after: get("/up"), same_puma_process: after&.dig(:pid) == pid_before,
    puma_after: after&.except(:pid),
    login_probes: probe ? { statuses: probes.map(&:first).tally, slowest_seconds: probes.map(&:last).max } : nil,
    pdf_uploads: pdf_statuses,
    pdf_workers_left: (pdf_workers(id) if pdf),
    normal_pdf_after: (@pdf_sessions.last.import(pdf_with_text("After the flood")) if pdf)
  }.compact
end

result = { image: IMAGE, memory_limit: MEMORY_LIMIT, sysctls: SYSCTLS, extra_env: EXTRA_ENV.keys, scenarios: [] }
name = nil
begin
  drop_databases
  name, id = start_container
  log "container #{name}, sysctls #{SYSCTLS.inspect}"
  deadline = monotonic + 120
  sleep 0.5 until get("/up") == "200" || monotonic > deadline
  raise "the server did not start" unless get("/up") == "200"

  enable_socket_accounting(id)
  sleep 3
  result[:cgroup] = cgroup_v1?(id) ? "v1 (socket buffers reported, not charged to the limit)" : "v2"
  result[:idle] = { memory_mib: memory(id), puma: puma(id)&.except(:pid) }
  log "idle #{result[:idle]}"
  scenario_keys = ENV.fetch("SCENARIOS", (SCENARIOS.keys + [ "waves10" ]).join(",")).split(",")
  if scenario_keys.any? { |key| SCENARIOS[key]&.key?(:pdf) }
    @pdf_sessions = create_pdf_accounts(name).each_with_index.map { |email, index| BreakerSession.new(email, "198.51.100.#{index + 1}") }
  end
  scenario_keys.each do |key|
    specs = if key.start_with?("waves")
      Array.new(Integer(key.delete_prefix("waves"))) { |i| SCENARIOS.fetch("c80").merge(label: "wave #{i + 1}: 80 chunked 30 MiB") }
    else
      [ SCENARIOS.fetch(key) ]
    end
    specs.each do |spec|
      outcome = begin
        run_scenario(id, **spec)
      rescue Errno::ENOENT, Errno::ESRCH
        raise "the web container exited during #{spec[:label]}"
      end
      result[:scenarios] << outcome
      log "#{outcome[:label]}: #{outcome.except(:label)}"
      raise "the web process did not survive #{outcome[:label]}" unless outcome[:up_after] == "200"
    end
  end
rescue StandardError => error
  result[:error] = "#{error.class}: #{error.message}"
  log result[:error]
ensure
  if name
    result[:container] = `docker inspect --format '{{.State.Status}} oom_killed={{.State.OOMKilled}}' #{name}`.strip
    system("docker", "rm", "-f", name, out: File::NULL, err: File::NULL)
  end
  drop_databases
  File.write(OUTPUT, JSON.pretty_generate(result))
  log "wrote #{OUTPUT} (#{result[:container]})"
end
