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
require "open3"
require "securerandom"
require "socket"

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
  "c200" => { label: "200 chunked 30 MiB, 64 KiB chunks", n: 200, bytes: 30 * MIB, chunk: 65_536, mode: :chunked }
}.freeze

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

def cgroup(id) = "/sys/fs/cgroup/system.slice/docker-#{id}.scope"

def memory(id)
  stat = File.read("#{cgroup(id)}/memory.stat")
  mib = ->(key) { (stat[/^#{key} (\d+)/, 1].to_i.to_f / MIB).round(1) }
  { current: (File.read("#{cgroup(id)}/memory.current").to_i.to_f / MIB).round(1), anon: mib["anon"], sock: mib["sock"], dirty: mib["file_dirty"] }
end

def oom_kills(id) = File.read("#{cgroup(id)}/memory.events")[/^oom_kill (\d+)/, 1].to_i

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

def run_scenario(id, label:, n:, probe: false, **request)
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
  gate = Queue.new
  senders = Array.new(n) { Thread.new { gate.pop; send_body(**request) } }
  sleep 0.2
  n.times { gate << true }
  statuses = senders.map(&:value).tally
  sleep 2
  running = false
  sampler.join
  prober.join if prober
  after = puma(id)
  {
    label:, statuses:, peak_mib: peaks.transform_values { |value| value.round(1) },
    oom_kills: oom_kills(id) - kills_before, up_after: get("/up"), same_puma_process: after&.dig(:pid) == pid_before,
    puma_after: after&.except(:pid),
    login_probes: probe ? { statuses: probes.map(&:first).tally, slowest_seconds: probes.map(&:last).max } : nil
  }
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

  sleep 3
  result[:idle] = { memory_mib: memory(id), puma: puma(id)&.except(:pid) }
  log "idle #{result[:idle]}"
  ENV.fetch("SCENARIOS", (SCENARIOS.keys + [ "waves10" ]).join(",")).split(",").each do |key|
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
