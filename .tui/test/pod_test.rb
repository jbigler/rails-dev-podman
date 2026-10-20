# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tmpdir"

# podman and systemctl are not installed where these tests run. The fixtures follow
# the tools' real output: podman's ListContainer / stats / events JSON (field names
# from podman's Go sources) and `systemctl show` blocks.
module PodTestHelpers
  # Collects what a command puts.
  class Outlet
    attr_reader :messages

    def initialize = @messages = Queue.new
    def put(msg) = @messages << msg

    def drain
      list = []
      list << @messages.pop until @messages.empty?
      list
    end
  end

  class Token
    def initialize = @canceled = false
    def canceled? = @canceled
    def cancel! = @canceled = true
  end

  # Runs block with PATH holding only the given fake programs (name => sh body).
  def with_fake_bin(programs)
    Dir.mktmpdir do |dir|
      programs.each do |name, body|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\nPATH=/usr/bin:/bin\n#{body}\n")
        File.chmod(0o755, path)
      end
      old = ENV["PATH"]
      ENV["PATH"] = dir
      yield dir
    ensure
      ENV["PATH"] = old
    end
  end

  # Starts cmd.call in a thread; returns [thread, outlet, token].
  def start(cmd)
    out = Outlet.new
    token = Token.new
    [Thread.new { cmd.call(out, token) }, out, token]
  end

  def stop(thread, token, within: 1.5)
    token.cancel!
    assert thread.join(within), "command did not return within #{within}s of cancel"
  end

  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

class UnitsParseTest < Minitest::Test
  SLUGS = %w[master tasks api api-v2].freeze

  def services
    @services ||= Wt::Sources::Units.parse(fixture("pod", "ps.json"), fixture("pod", "show.txt"), prefix: "filial", slugs: SLUGS)
  end

  def svc(slug, name) = services.fetch(slug).find { it.name == name }

  def test_every_slug_gets_every_service_in_order
    assert_equal SLUGS, services.keys
    services.each_value { assert_equal Wt::Service::NAMES, it.map(&:name) }
    assert_equal "filial-db@tasks.service", svc("tasks", "db").unit
  end

  def test_merge_rule_states
    assert_equal :running, svc("tasks", "rails").state
    assert_equal :healthy, svc("tasks", "db").state
    assert_equal :starting, svc("tasks", "rustfs").state, "container health starting"
    assert_equal :starting, svc("api", "redis").state, "unit activating, no container yet"
    assert_equal :stopped, svc("tasks", "playwright").state, "exited 0 is a clean stop"
    assert_equal :stopped, svc("api", "rustfs").state, "created, never started"
    assert_equal :stopped, svc("master", "rails").state
  end

  def test_unhealthy_container_is_running_with_detail
    redis = svc("tasks", "redis")
    assert_equal :running, redis.state
    assert_equal "unhealthy", redis.detail
  end

  def test_failed_unit_wins_over_exited_container
    rails = svc("api", "rails")
    assert_equal :failed, rails.state
    assert_equal "exit-code", rails.detail
  end

  def test_nonzero_exit_is_exited_with_code
    db = svc("api", "db")
    assert_equal :exited, db.state
    assert_equal "exited 137", db.detail
    assert_nil db.port, "a stopped service shows no port"
    assert_nil db.started_at
  end

  def test_port_is_the_main_published_port_not_the_debug_port
    assert_equal 13_001, svc("tasks", "rails").port
    assert_equal 55_433, svc("tasks", "db").port
    assert_equal 19_001, svc("tasks", "rustfs").port
    assert_nil svc("tasks", "redis").port, "redis publishes nothing"
  end

  def test_started_at_comes_from_the_container
    assert_equal Time.at(1_799_994_000), svc("tasks", "rails").started_at
    assert_equal Time.at(1_799_999_992), svc("tasks", "rustfs").started_at
  end

  def test_slug_does_not_capture_a_longer_slug_with_the_same_start
    assert_equal :failed, svc("api", "rails").state
    assert_equal :running, svc("api-v2", "rails").state
    assert_equal 13_003, svc("api-v2", "rails").port
    assert_equal :exited, svc("api", "db").state
    assert_equal :healthy, svc("api-v2", "db").state
  end

  def test_unit_timestamp_is_the_fallback_for_an_active_unit
    ps = JSON.generate([{ "Names" => ["filial-tasks-rails"], "State" => "running", "Status" => "", "ExitCode" => 0,
                          "StartedAt" => -62_135_596_800, "Ports" => [] }])
    show = "Result=success\nId=filial-rails@tasks.service\nActiveState=active\nSubState=running\nActiveEnterTimestamp=@1799990000\n"
    rails = Wt::Sources::Units.parse(ps, show, prefix: "filial", slugs: ["tasks"])["tasks"].first
    assert_equal Time.at(1_799_990_000), rails.started_at
  end

  def test_empty_podman_output_means_everything_stopped
    result = Wt::Sources::Units.parse("", fixture("pod", "show.txt"), prefix: "filial", slugs: ["api"])
    assert_equal :failed, result["api"].first.state
    assert_equal %i[stopped starting stopped stopped], result["api"].drop(1).map(&:state)
  end
end

class UnitsFetchTest < Minitest::Test
  include PodTestHelpers

  def test_one_ps_and_one_systemctl_call_for_every_unit
    ps = fixture_path("pod", "ps.json")
    show = fixture_path("pod", "show.txt")
    with_fake_bin("podman" => "echo \"$@\" >> \"$(dirname \"$0\")/podman.calls\"\ncat #{ps}",
                  "systemctl" => "echo \"$@\" >> \"$(dirname \"$0\")/systemctl.calls\"\ncat #{show}") do |dir|
      msg = Wt::Sources::Units.fetch(config, %w[master tasks api api-v2])
      assert_equal :healthy, msg.services["tasks"].find { it.name == "db" }.state

      assert_equal ["ps -a --format json --filter name=^filial-"], File.readlines(File.join(dir, "podman.calls"), chomp: true)
      calls = File.readlines(File.join(dir, "systemctl.calls"), chomp: true)
      assert_equal 1, calls.size
      assert_includes calls.first, "filial-playwright@api-v2.service"
      assert_equal 20, calls.first.scan(".service").size
    end
  end

  def test_missing_podman_becomes_a_source_failure
    with_fake_bin("systemctl" => "exit 0") do
      out = Outlet.new
      Wt::Commands.fetch(model, "units", Wt::Sources::Units, config, ["tasks"]).call(out, Token.new)
      msg = out.drain.first
      assert_kind_of Wt::Msg::SourceFailed, msg.message
      m, = step(model, msg)
      assert m.failures.key?("units")
    end
  end
end

class StatsParseTest < Minitest::Test
  def test_only_the_worktrees_containers_with_parsed_values
    stats = Wt::Sources::Stats.parse(fixture("pod", "stats.json"), prefix: "filial", slug: "tasks")
    assert_equal %w[filial-tasks-rails filial-tasks-db filial-tasks-redis filial-tasks-nvim], stats.keys
    rails = stats["filial-tasks-rails"]
    assert_in_delta 3.8, rails.cpu
    assert_equal 598_200_000, rails.mem
    assert_equal 9_437_000, stats["filial-tasks-redis"].mem
    assert_in_delta 0.0, stats["filial-tasks-nvim"].cpu
  end

  def test_slug_isolation
    assert_equal %w[filial-api-v2-rails], Wt::Sources::Stats.parse(fixture("pod", "stats.json"), prefix: "filial", slug: "api-v2").keys
    assert_empty Wt::Sources::Stats.parse(fixture("pod", "stats.json"), prefix: "filial", slug: "api")
  end

  def test_unreadable_values_are_nil
    json = JSON.generate([{ "name" => "filial-tasks-db", "cpu_percent" => "--", "mem_usage" => "-- / --" }])
    s = Wt::Sources::Stats.parse(json, prefix: "filial", slug: "tasks")["filial-tasks-db"]
    assert_nil s.cpu
    assert_nil s.mem
    assert_equal 1_288_490_189, Wt::Sources::Stats.bytes("1.2GiB / 31.1GiB")
  end
end

class PodmanEventsTest < Minitest::Test
  include PodTestHelpers

  def events(name) = fixture_path("pod", name)

  def test_debounces_bursts_to_leading_and_trailing_reports
    life = events("events_lifecycle.jsonl")
    with_fake_bin("podman" => "cat #{life}\nsleep 0.2\ncat #{life}\nexec sleep 30") do
      t0 = mono
      thread, out, token = start(Wt::Commands::PodmanEvents.new(config:))
      sleep 1.0
      stop(thread, token)
      msgs = out.drain
      assert_equal 2, msgs.size, "6 lifecycle events → one report at once, one when the 0.5 s window closes"
      assert(msgs.all? { it.is_a?(Wt::Msg::UnitsDirty) })
      assert_operator mono - t0, :>=, 0.5
    end
  end

  def test_ignores_other_projects_exec_and_repeated_health
    ev = events("events.jsonl")
    with_fake_bin("podman" => "cat #{ev}\nsleep 0.7\ncat #{ev}\nexec sleep 30") do
      thread, out, token = start(Wt::Commands::PodmanEvents.new(config:))
      sleep 1.3
      stop(thread, token)
      assert_equal 1, out.drain.size, "only the first health result for filial-tasks-db changes anything"
    end
  end

  def test_missing_podman_backs_off_and_stops_on_cancel
    with_fake_bin({}) do
      thread, out, token = start(Wt::Commands::PodmanEvents.new(config:))
      sleep 0.3
      stop(thread, token, within: 0.5)
      assert_empty out.drain
    end
  end

  def test_dead_stream_is_not_restarted_in_a_loop
    with_fake_bin("podman" => "echo x >> \"$(dirname \"$0\")/runs\"\nexit 125") do |dir|
      thread, _out, token = start(Wt::Commands::PodmanEvents.new(config:))
      sleep 0.6
      stop(thread, token)
      assert_equal 1, File.readlines(File.join(dir, "runs")).size
    end
  end

  def test_cancel_kills_the_child
    with_fake_bin("podman" => "echo $$ > \"$(dirname \"$0\")/pid\"\nexec sleep 30") do |dir|
      thread, _out, token = start(Wt::Commands::PodmanEvents.new(config:))
      sleep 0.3
      pid = File.read(File.join(dir, "pid")).to_i
      stop(thread, token)
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  end
end

class LogStreamTest < Minitest::Test
  include PodTestHelpers

  def stream(svc = "rails") = Wt::Commands::LogStream.new(config:, slug: "tasks", svc:)

  def test_follows_the_container_in_batches
    body = <<~SH
      case "$1" in
        container) [ "$3" = filial-tasks-rails ] && exit 0 || exit 1 ;;
        logs) echo "$@" > "$(dirname "$0")/args"; i=1; while [ $i -le 300 ]; do echo "line $i"; i=$((i+1)); done; echo "oops" >&2; exec sleep 30 ;;
      esac
    SH
    with_fake_bin("podman" => body) do |dir|
      thread, out, token = start(stream)
      sleep 0.6
      stop(thread, token)
      batches = out.drain
      assert(batches.all? { it.is_a?(Wt::Msg::LogLines) })
      lines = batches.flat_map(&:lines)
      assert_equal (1..300).map { "line #{it}" } + ["oops"], lines, "stdout and stderr, in order"
      assert_operator batches.size, :<, 10, "lines are batched, not one message each"
      assert_equal "logs -f --tail 200 filial-tasks-rails", File.read(File.join(dir, "args")).strip
    end
  end

  def test_missing_container_is_said_once
    with_fake_bin("podman" => "exit 1") do
      thread, out, token = start(stream("db"))
      sleep 0.3
      stop(thread, token)
      assert_equal [["── no container filial-tasks-db (yet); see mise run status"]], out.drain.map(&:lines)
    end
  end

  def test_oneshot_units_follow_the_journal_like_cmd_logs
    assert_equal %w[journalctl --user -f -u filial-deps@tasks.service -o cat -n 200], stream("deps").argv
    assert_equal "podman", stream("rustfs").argv.first
  end
end

class PodActionsTest < Minitest::Test
  # Shareable like the runtime's model, so the asserts below catch what an action adds.
  def tasks_model(**ui)
    m = model(**ui)
    Ractor.make_shareable(m.with(ui: m.ui.with(selected: "tasks")))
  end

  def with_services(m, *states)
    m.put(:services, "tasks", Wt::Service::NAMES.zip(states).map { |n, s| Wt::Service.new(name: n, state: s || :stopped) })
  end

  def test_toggle_pod_stops_when_anything_is_up
    _, cmd = step(with_services(tasks_model, :stopped, :healthy), "s")
    assert_equal ["stop"], cmd.args
    assert_equal "/ws/tasks", cmd.cwd
  end

  def test_toggle_pod_starts_when_everything_is_down
    _, cmd = step(with_services(tasks_model, :stopped, :failed, :exited), "s")
    assert_equal ["up"], cmd.args
    _, cmd = step(tasks_model, "s")
    assert_equal ["up"], cmd.args, "no unit data yet"
  end

  def test_restart_prompts_with_the_followed_service_then_runs_restart
    m, = step(tasks_model, "r")
    p = m.ui.prompt
    assert_equal ["restart service", "rails", :restart_service_named, ["tasks"]], [p.label, p.text, p.action, p.args]
    assert Ractor.shareable?(m)
    m, cmd = step(m, "backspace", "backspace", "backspace", "backspace", "backspace", "d", "b", "enter")
    assert_kind_of Wt::Commands::MiseTask, cmd
    assert_equal %w[restart db], cmd.args
    assert_equal "/ws/tasks", cmd.cwd
    assert_nil m.ui.prompt
  end

  def test_restart_rejects_unknown_service
    m, = step(tasks_model, "r", "backspace", "backspace", "backspace", "backspace", "backspace", "x", "enter")
    assert_equal :error, m.ui.toasts.last.level
    assert_includes m.ui.toasts.last.text, "unknown service x"
  end

  def test_logs_full_tier_starts_a_stream
    m, cmd = step(tasks_model(width: 240), "L", "enter")
    stream = Wt::Commands::LogStream.new(config:, slug: "tasks", svc: "rails")
    assert_equal stream, m.log_stream
    assert_equal stream, cmd
    assert Ractor.shareable?(m)
  end

  def test_logs_switching_service_cancels_the_old_stream_and_starts_the_new
    m, = step(tasks_model(width: 240), "L", "enter")
    old = m.log_stream
    m = m.with(log_lines: ["old line"].freeze)
    m, cmd = step(m, "L", "backspace", "backspace", "backspace", "backspace", "backspace", "d", "b", "enter")
    assert_equal "db", m.ui.log_service
    assert_empty m.log_lines
    assert_equal "db", m.log_stream.svc
    assert Ractor.shareable?(m)

    # Each delivered message dispatches its command at the top level.
    dispatched = cmd.commands.map { step(m, it.message).last }
    assert_includes dispatched, Rooibos::Command.cancel(old)
    assert_includes dispatched, m.log_stream
  end

  def test_logs_same_service_keeps_the_stream_and_its_lines
    m, = step(tasks_model(width: 240), "L", "enter")
    m = m.with(log_lines: ["kept"].freeze)
    m2, cmd = step(m, "L", "enter")
    assert_nil cmd
    assert_equal ["kept"], m2.log_lines
    assert_equal m.log_stream, m2.log_stream
  end

  def test_logs_narrow_tier_hands_the_terminal_to_mise
    calls = []
    Wt::Terminal.stub(:handover, ->(argv, chdir:) { calls << [argv, chdir] }) do
      m, cmd = step(tasks_model(width: 140), "L", "backspace", "backspace", "backspace", "backspace", "backspace", "d", "b", "enter")
      assert_nil cmd
      assert_nil m.log_stream
    end
    assert_equal [[%w[mise run logs db], "/ws/tasks"]], calls
  end

  def test_new_worktree_runs_wt_from_the_root
    m, = step(tasks_model, "c")
    assert_equal "new worktree (branch or PR#)", m.ui.prompt.label
    _, cmd = step(m, "4", "2", "enter")
    assert_equal %w[wt 42], cmd.args
    assert_equal "/ws", cmd.cwd
  end

  def test_remove_worktree_confirms_then_runs_wt_rm
    m, = step(tasks_model, "d")
    assert_equal "Remove worktree tasks? Runs wt:rm (stops its pod, deletes its volumes).", m.ui.confirm.prompt
    assert Ractor.shareable?(m)
    _, cmd = step(m, "y")
    assert_equal ["wt:rm", "tasks"], cmd.args
    assert_equal "/ws", cmd.cwd
  end

  def test_remove_base_worktree_is_refused_without_a_dialog
    m, = step(model, "d")
    assert_nil m.ui.confirm
    assert_equal :error, m.ui.toasts.last.level
  end

  def test_units_dirty_refetches_units_unless_already_in_flight
    m, cmd = step(model, Wt::Msg::UnitsDirty.new)
    assert_includes m.inflight, "units"
    refute_nil cmd
    _, cmd = step(m, Wt::Msg::UnitsDirty.new)
    assert_nil cmd
  end
end
