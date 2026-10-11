require "test_helper"
require "open3"
require "tmpdir"
require Rails.root.join("script/evaluations/cloudflare_tunnel/edge").to_s

# script/evaluations/cloudflare_tunnel is a manual Docker evaluation, so it is
# not run here. These cover the parts that make it a gate: its expectations
# reject unsafe proxy behavior, and it fails promptly, with diagnostics,
# when its database never becomes ready.
class CloudflareTunnelEvaluationTest < ActiveSupport::TestCase
  RUN_SCRIPT = Rails.root.join("script/evaluations/cloudflare_tunnel/run.sh").to_s
  LIMITED = [ "422" ] * 10 + [ "429" ]
  ISOLATED = { "A" => LIMITED, "B" => [ "422" ], "C" => LIMITED, "D" => LIMITED, "E" => [ "422" ] }.freeze
  EDGE = "172.18.0.9"

  test "the isolated expectation accepts only independent, spoof-proof budgets" do
    assert_empty TunnelEdge.sign_in_failures("isolated", ISOLATED)

    {
      "B" => [ "429" ],         # a distinct visitor shares A's budget
      "C" => [ "422" ] * 11,    # rotating spoofed headers escape the limit
      "D" => [ "422" ] * 11,    # claiming the victim's address escapes it
      "E" => [ "429" ],         # the victim was charged for D's attempts
      "A" => [ "422" ] * 11     # the limit is not enforced at all
    }.each do |scenario, statuses|
      failures = TunnelEdge.sign_in_failures("isolated", ISOLATED.merge(scenario => statuses))
      assert_equal 1, failures.size, scenario
      assert_match(/\Asign-in #{scenario}: /, failures.first)
    end
    assert_match(/sign-in C: got nil/, TunnelEdge.sign_in_failures("isolated", ISOLATED.except("C")).sole)
  end

  test "the isolated expectation requires Rails to see each visitor's own address" do
    observed = { "plain client" => %w[198.51.100.21 198.51.100.21], "client spoofing another visitor" => %w[198.51.100.21 198.51.100.21] }
    assert_empty TunnelEdge.echo_failures("isolated", observed, EDGE)

    [ "198.51.100.22", EDGE, "203.0.113.9", "IpSpoofAttackError: spoofed" ].each do |remote_ip|
      failures = TunnelEdge.echo_failures("isolated", observed.merge("client spoofing another visitor" => [ "198.51.100.21", remote_ip ]), EDGE)
      assert_equal [ "echo client spoofing another visitor: Rails saw #{remote_ip.inspect}, expected \"198.51.100.21\"" ], failures
    end
  end

  test "the forwarding-off control fails when it cannot reproduce the shared budget" do
    shared = { "A" => LIMITED, "B" => [ "429" ], "E" => [ "429" ] }
    assert_empty TunnelEdge.sign_in_failures("shared", shared)
    assert_empty TunnelEdge.echo_failures("shared", { "plain client" => [ "198.51.100.21", EDGE ] }, EDGE)

    assert_equal 2, TunnelEdge.sign_in_failures("shared", ISOLATED).size
    assert_not_empty TunnelEdge.echo_failures("shared", { "plain client" => %w[198.51.100.21 198.51.100.21] }, EDGE)
    assert_raises(ArgumentError) { TunnelEdge.sign_in_failures("unsafe", ISOLATED) }
  end

  test "the evaluation fails at once with diagnostics when PostgreSQL exits" do
    stderr, status, elapsed, calls = run_with_docker_state("exited (exit code 1)", timeout: 60)

    assert_not status.success?
    assert_operator elapsed, :<, 30, "it waited for a container that had stopped"
    assert_match(/FAIL: PostgreSQL not ready after \d+s \(limit 60s\); container th-tunnel-\d+-pg: exited \(exit code 1\)/, stderr)
    assert_match(/No space left on device/, stderr)
    assert_cleaned_up_before_starting_the_application(calls)
  end

  test "the evaluation stops waiting for PostgreSQL after READY_TIMEOUT" do
    stderr, status, elapsed, calls = run_with_docker_state("running (exit code 0)", timeout: 2)

    assert_not status.success?
    assert_operator elapsed, :<, 30
    assert_match(/FAIL: PostgreSQL not ready after [23]s \(limit 2s\); container th-tunnel-\d+-pg: running/, stderr)
    assert_cleaned_up_before_starting_the_application(calls)
  end

  private

  # A docker stand-in on PATH: every exec (the readiness probe) fails and
  # inspect reports STATE, so no Docker daemon is needed or touched.
  def run_with_docker_state(state, timeout:)
    Dir.mktmpdir("tunnel-evaluation") do |directory|
      log = File.join(directory, "calls")
      File.write(File.join(directory, "docker"), <<~SH, perm: 0o755)
        #!/usr/bin/env bash
        echo "$*" >> "#{log}"
        case "$1" in
          exec) exit 1 ;;
          inspect) echo "#{state}" ;;
          logs) echo "initdb: error: could not create directory: No space left on device" ;;
          run) echo stand-in-container-id ;;
        esac
      SH
      environment = { "PATH" => "#{directory}:#{ENV.fetch("PATH")}", "IMAGE" => "evaluation:never-started", "READY_TIMEOUT" => timeout.to_s }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # timeout keeps an unbounded wait from hanging the suite.
      _, stderr, status = Open3.capture3(environment, "timeout", "60", "bash", RUN_SCRIPT)
      [ stderr, status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, File.readlines(log, chomp: true) ]
    end
  end

  def assert_cleaned_up_before_starting_the_application(calls)
    assert calls.any? { |call| call.match?(/\Arm -fv th-tunnel-\d+-pg /) }, calls.inspect
    assert calls.any? { |call| call.match?(/\Anetwork rm th-tunnel-\d+\z/) }, calls.inspect
    assert_empty calls.grep(/evaluation:never-started/), "the application started without a database"
  end
end
