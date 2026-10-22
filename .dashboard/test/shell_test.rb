# frozen_string_literal: true

require "test_helper"
require "socket"

class ShellTest < Minitest::Test
  def test_missing_binary_is_status_127
    result = Dashboard::Shell::Real.new.run(["no-such-binary-xyz"])

    assert_equal 127, result.status
    assert_predicate result, :broken?
  end

  # The dashboard runs under `bundle exec`; what it spawns (mise, gh, git, a
  # terminal) must not load its bundle.
  def test_children_do_not_inherit_the_dashboards_bundle
    assert ENV.key?("BUNDLE_GEMFILE"), "the test process should run under Bundler"
    shell = Dashboard::Shell::Real.new.run(["env"], env: { "EXTRA" => "1" }).stdout
    logs = Dir.mktmpdir("shell-logs")
    child = Dashboard::Runner::Spawn.new("#{logs}/jobs").spawn(["env"], env: { "EXTRA" => "1" }, chdir: Dir.tmpdir, job: 1)
    spawned = +""
    child.each_line { spawned << it << "\n" }

    [shell, spawned].each do |text|
      vars = text.lines(chomp: true).to_h { it.split("=", 2) }
      assert_empty vars.keys.grep(/\ABUNDLER?_/)
      refute_match(/bundler/, vars["RUBYOPT"].to_s)
      refute_match(%r{vendor/bundle}, vars["GEM_HOME"].to_s)
      assert_equal "1", vars["EXTRA"]
      assert_equal ENV["HOME"], vars["HOME"]
    end
  ensure
    FileUtils.rm_rf(logs) if logs
  end

  # Falcon clears close-on-exec on its listening socket. A child that kept it
  # (an action in its own systemd scope outlives the dashboard) held the port,
  # and the next start failed with EADDRINUSE until the action ended.
  def test_children_do_not_inherit_open_sockets
    server = TCPServer.new("127.0.0.1", 0)
    server.close_on_exec = false
    fd = server.fileno.to_s
    list = ["sh", "-c", "ls /proc/$$/fd"]
    shell = Dashboard::Shell::Real.new.run(list).stdout.split
    logs = Dir.mktmpdir("shell-logs")
    child = Dashboard::Runner::Spawn.new("#{logs}/jobs").spawn(list, env: {}, chdir: Dir.tmpdir, job: 1)
    spawned = []
    child.each_line { spawned << it }

    refute_includes shell, fd, "Shell::Real passed the listening socket on"
    refute_includes spawned, fd, "Runner::Spawn passed the listening socket on"
  ensure
    server&.close
    FileUtils.rm_rf(logs) if logs
  end

  def test_timeout_kills_the_group
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Dashboard::Shell::Real.new.run(["sh", "-c", "sleep 5 & sleep 5"], timeout: 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    assert_operator elapsed, :<, 2
  end

  def test_timeout_holds_when_a_descendant_keeps_the_pipes
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Dashboard::Shell::Real.new.run(["sh", "-c", "sleep 3 & echo hi"], timeout: 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    assert_operator elapsed, :<, 2
  end
end
