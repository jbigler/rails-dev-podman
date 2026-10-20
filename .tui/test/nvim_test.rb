# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "tmpdir"

# nvim and kitten are not installed where these run: Shell.capture is stubbed
# with stdout/stderr in the shape `nvim --remote-expr` / `--remote-send` print
# (fixtures/nvim: --remote-expr writes the string result with no newline; a
# refused port is E247 on stderr).
module NvimTestHelpers
  def res(stdout: "", stderr: "", status: 0, timed_out: false)
    Wt::Shell::Result.new(stdout:, stderr:, status:, timed_out:)
  end

  def refused(kind = "expr") = res(stderr: fixture("nvim", "refused_#{kind}.stderr"), status: 1)

  # Stubs Shell.capture with queued results; returns the argv of every call.
  def capturing(*results)
    calls = []
    Wt::Shell.stub(:capture, lambda { |argv, **opts|
      calls << [argv, opts]
      results.shift || raise("unexpected call #{argv.inspect}")
    }) { yield }
    calls
  end

  def with_env(vars)
    old = vars.keys.to_h { [it, ENV[it]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # PATH without kitten (and with it, when asked), no kitty socket, no $TERMINAL.
  def with_launch_env(kitten: false, kitty_socket: nil, terminal: nil, &)
    Dir.mktmpdir do |dir|
      if kitten
        File.write(File.join(dir, "kitten"), "#!/bin/sh\n")
        File.chmod(0o755, File.join(dir, "kitten"))
      end
      with_env({ "PATH" => dir, "KITTY_LISTEN_ON" => kitty_socket, "TERMINAL" => terminal }, &)
    end
  end

  # Collects what a custom command puts.
  class Out
    attr_reader :messages

    def initialize = @messages = []
    def put(msg) = @messages << msg
  end

  Token = Struct.new(:canceled?)

  def run_command(cmd)
    out = Out.new
    cmd.call(out, Token.new(false))
    out.messages
  end

  def with_calls(locations_list, **ui)
    calls = locations_list.each_with_index.map do |(locations, kind), i|
      Wt::ToolCall.new(id: "t#{i}", kind: kind || "edit", locations:)
    end
    m = model
    sessions = Ractor.make_shareable({ "tasks" => Wt::AgentSession.new(slug: "tasks", tool_calls: calls) })
    m.with(sessions:, ui: m.ui.with(selected: "tasks", **ui))
  end

  def attached(m, uis = 1)
    m.put(:nvim, "tasks", Wt::NvimStatus.new(running: true, ui_count: uis))
  end
end

class NvimStatusSourceTest < Minitest::Test
  include NvimTestHelpers

  def test_parse_reads_ui_count_buffers_and_worktree_relative_file
    s = Wt::Sources::Nvim.parse(fixture("nvim", "status.json"))
    assert s.running
    assert_equal 1, s.ui_count
    assert_equal 4, s.buffers
    assert_equal 1, s.modified
    assert_equal "app/models/task.rb", s.file
    assert_equal 42, s.line
  end

  def test_parse_without_a_file_has_no_file_or_line
    s = Wt::Sources::Nvim.parse(fixture("nvim", "status_no_file.json"))
    assert_equal 0, s.ui_count
    assert_nil s.file
    assert_nil s.line
  end

  def test_parse_accepts_string_wrapped_result
    s = Wt::Sources::Nvim.parse("'#{fixture('nvim', 'status.json')}'\n")
    assert_equal "app/models/task.rb", s.file
  end

  def test_parse_rejects_garbage
    assert_raises(Wt::Error) { Wt::Sources::Nvim.parse("E15: Invalid expression") }
    assert_raises(Wt::Error) { Wt::Sources::Nvim.parse("[]") }
  end

  def test_fetch_asks_the_worktree_port_once
    msg = nil
    calls = capturing(res(stdout: fixture("nvim", "status.json"))) { msg = Wt::Sources::Nvim.fetch(config, "tasks", 17_001) }
    argv, = calls.first
    assert_equal 1, calls.size
    assert_equal ["nvim", "--server", "127.0.0.1:17001", "--remote-expr"], argv[0, 4]
    assert_includes argv[4], "nvim_list_uis()"
    assert_equal "tasks", msg.slug
    assert_equal 1, msg.status.ui_count
  end

  def test_refused_port_is_stopped_not_a_failure
    msg = nil
    capturing(refused) { msg = Wt::Sources::Nvim.fetch(config, "tasks", 17_001) }
    assert_instance_of Wt::Msg::NvimLoaded, msg
    refute msg.status.running
  end

  def test_missing_nvim_is_stopped
    msg = nil
    capturing(res(stderr: "No such file or directory - nvim", status: 127)) { msg = Wt::Sources::Nvim.fetch(config, "tasks", 17_001) }
    refute msg.status.running
  end

  def test_hung_server_is_a_source_failure
    capturing(res(timed_out: true, status: nil)) do
      assert_raises(Wt::Error) { Wt::Sources::Nvim.fetch(config, "tasks", 17_001) }
    end
  end
end

class NvimWriteAllTest < Minitest::Test
  include NvimTestHelpers

  def wt = worktree("tasks")

  def test_unreachable_server_has_nothing_to_save
    r = nil
    calls = capturing(refused) { r = Wt::Nvim.write_all(config, wt) }
    assert r.ok?
    assert_equal 1, calls.size
  end

  def test_no_modified_buffers_skips_the_write
    r = nil
    calls = capturing(res(stdout: fixture("nvim", "none_modified.json"))) { r = Wt::Nvim.write_all(config, wt) }
    assert r.ok?
    assert_equal 1, calls.size
  end

  def test_modified_buffers_are_written_and_verified
    r = nil
    calls = capturing(res(stdout: fixture("nvim", "modified.json")), res(stdout: fixture("nvim", "none_modified.json"))) do
      r = Wt::Nvim.write_all(config, wt)
    end
    assert r.ok?
    assert_equal 2, calls.size
    assert_includes calls[1][0].last, "wa"
  end

  def test_buffers_still_modified_after_wa_fail_with_their_names
    r = nil
    capturing(res(stdout: fixture("nvim", "modified.json")), res(stdout: fixture("nvim", "modified_after_wa.json"))) do
      r = Wt::Nvim.write_all(config, wt)
    end
    refute r.ok?
    assert_match(/config\/routes\.rb/, r.error_line)
    refute_match(/task\.rb/, r.error_line)
  end

  def test_wa_erroring_fails
    r = nil
    capturing(res(stdout: fixture("nvim", "modified.json")), res(stderr: "E212: Can't open file for writing", status: 1)) do
      r = Wt::Nvim.write_all(config, wt)
    end
    refute r.ok?
    assert_match(/E212/, r.error_line)
  end

  def test_hung_server_fails_rather_than_pretending_saved
    r = nil
    capturing(res(timed_out: true, status: nil)) { r = Wt::Nvim.write_all(config, wt) }
    refute r.ok?
  end
end

class NvimPathTest < Minitest::Test
  include NvimTestHelpers

  def test_worktree_paths_map_to_app
    assert_equal "/app/app/models/task.rb", Wt::Nvim.container_path(config, "tasks", "/ws/tasks/app/models/task.rb")
    assert_equal "/app", Wt::Nvim.container_path(config, "tasks", "/ws/tasks")
  end

  def test_paths_outside_the_worktree_are_not_opened
    assert_nil Wt::Nvim.container_path(config, "api", "/ws/api-v2/app.rb")
    assert_nil Wt::Nvim.container_path(config, "api", "/ws/apiary")
    assert_nil Wt::Nvim.container_path(config, "api", "/ws/api/../tasks/x.rb")
    assert_nil Wt::Nvim.container_path(config, "api", "/etc/passwd")
    assert_nil Wt::Nvim.container_path(config, "api", "app/models/x.rb")
  end

  def test_open_keys_escape_the_file_name
    assert_equal "<C-\\><C-n>:drop /app/a\\ b.rb<CR>:7<CR>", Wt::Nvim.open_keys("/app/a b.rb", 7)
    assert_equal "<C-\\><C-n>:drop /app/\\%\\<lt>x>.rb<CR>", Wt::Nvim.open_keys("/app/%<x>.rb", nil)
  end
end

class NvimActionsTest < Minitest::Test
  include NvimTestHelpers

  def test_n_hands_over_in_the_worktree_and_refreshes_nvim
    handed = nil
    m, cmd = Wt::Terminal.stub(:handover, ->(argv, chdir:) { handed = [argv, chdir]; 0 }) do
      Rooibos.normalize_init(Wt::Actions.nvim_here(with_calls([])))
    end
    assert_equal [%w[mise run nvim], "/ws/tasks"], handed
    assert_includes m.inflight, "nvim:tasks"
    refute_nil cmd
  end

  def test_N_prefers_kitty_remote_control
    with_launch_env(kitty_socket: "unix:/tmp/kitty", terminal: "foot") do
      _, cmd = Wt::Actions.nvim_window(with_calls([]))
      kinds = cmd.launchers.map(&:first)
      assert_equal %i[capture spawn], kinds
      assert_equal ["kitten", "@", "launch", "--type=os-window", "--cwd=/ws/tasks", "mise", "run", "nvim"], cmd.launchers[0][1]
    end
  end

  def test_N_uses_kitten_found_on_path
    with_launch_env(kitten: true) do
      _, cmd = Wt::Actions.nvim_window(with_calls([]))
      assert_equal "kitten", cmd.launchers.first[1].first
    end
  end

  def test_N_falls_back_to_terminal
    with_launch_env(terminal: "foot --app-id x") do
      _, cmd = Wt::Actions.nvim_window(with_calls([]))
      assert_equal [[:spawn, ["foot", "--app-id", "x", "-e", "mise", "run", "nvim"]]], cmd.launchers
    end
  end

  def test_N_falls_back_to_n_without_any_launcher
    handed = false
    with_launch_env do
      Wt::Terminal.stub(:handover, ->(*, **) { handed = true; 0 }) { Wt::Actions.nvim_window(with_calls([])) }
    end
    assert handed
  end

  def test_window_tries_terminal_when_kitten_fails
    cmd = Wt::Nvim::LaunchWindow.new(label: "nvim window", slug: "tasks", cwd: "/ws/tasks",
                                     launchers: Ractor.make_shareable([[:capture, %w[kitten @ launch]], [:spawn, %w[foot -e mise run nvim]]]),
                                     timeout: 5.0)
    spawned = nil
    msgs = nil
    capturing(res(stderr: "Error: Remote control is disabled", status: 1)) do
      Process.stub(:spawn, ->(*argv, **opts) { spawned = [argv, opts[:chdir]]; 4242 }) do
        Process.stub(:detach, ->(_pid) {}) { msgs = run_command(cmd) }
      end
    end
    assert_equal [%w[foot -e mise run nvim], "/ws/tasks"], spawned
    assert_equal 0, msgs.last.status
  end

  def test_window_reports_failure_when_nothing_starts
    cmd = Wt::Nvim::LaunchWindow.new(label: "nvim window", slug: "tasks", cwd: "/ws/tasks",
                                     launchers: Ractor.make_shareable([[:spawn, %w[no-such-terminal-xyz -e x]]]), timeout: 5.0)
    msgs = run_command(cmd)
    refute_equal 0, msgs.last.status
    assert_match(/no-such-terminal-xyz/, msgs.last.stderr)
  end

  def test_o_sends_drop_for_the_latest_located_call_when_a_ui_is_attached
    m = attached(with_calls([[[{ path: "/ws/tasks/app/a.rb", line: 3 }]], [[{ path: "/ws/tasks/app/b.rb", line: 42 }]], [[]]]))
    _, cmd = Wt::Actions.open_tool_call(m)
    assert_empty cmd.launchers
    calls = capturing(res) { run_command(cmd) }
    assert_equal ["nvim", "--server", "127.0.0.1:17001", "--remote-send", "<C-\\><C-n>:drop /app/app/b.rb<CR>:42<CR>"], calls.first[0]
  end

  def test_o_follows_the_selected_tool_call
    m = attached(with_calls([[[{ "path" => "/ws/tasks/app/a.rb", "line" => 3 }]], [[{ path: "/ws/tasks/app/b.rb" }]]], tool_index: 0))
    _, cmd = Wt::Actions.open_tool_call(m)
    assert_equal "<C-\\><C-n>:drop /app/app/a.rb<CR>:3<CR>", cmd.payload
  end

  def test_o_refuses_paths_outside_the_worktree
    m, = Wt::Actions.open_tool_call(attached(with_calls([[[{ path: "/ws/tasks-old/app/a.rb", line: 1 }]]])))
    assert_equal :error, m.ui.toasts.last.level
    assert_match(/outside/, m.ui.toasts.last.text)
  end

  def test_o_without_located_tool_call_toasts
    m, = Wt::Actions.open_tool_call(with_calls([[[]]]))
    assert_match(/no tool call/, m.ui.toasts.last.text)
  end

  def test_o_with_no_ui_opens_a_window_then_waits_for_the_server
    with_launch_env(kitty_socket: "unix:/tmp/kitty") do
      _, cmd = Wt::Actions.open_tool_call(attached(with_calls([[[{ path: "/ws/tasks/app/a.rb", line: 1 }]]]), 0))
      assert_equal :capture, cmd.launchers.first.first
      msgs = nil
      calls = capturing(res, refused("send"), res) { msgs = run_command(cmd) }
      assert_equal "kitten", calls[0][0].first
      assert_equal "--remote-send", calls[2][0][3]
      assert_equal 0, msgs.last.status
    end
  end

  def test_o_with_no_ui_and_no_window_sends_then_attaches_here
    order = []
    with_launch_env do
      Wt::Shell.stub(:capture, ->(argv, **) { order << argv[3]; res }) do
        Wt::Terminal.stub(:handover, ->(*, **) { order << :handover; 0 }) do
          Wt::Actions.open_tool_call(with_calls([[[{ path: "/ws/tasks/app/a.rb", line: 1 }]]]))
        end
      end
    end
    assert_equal ["--remote-send", :handover], order
  end

  def test_d_diffs_the_latest_edit_with_gitsigns_or_git_show
    m = attached(with_calls([[[{ path: "/ws/tasks/app/a.rb", line: 5 }], "edit"], [[{ path: "/ws/tasks/app/b.rb" }], "read"]]))
    _, cmd = Wt::Actions.show_diff(m)
    assert_equal :expr, cmd.mode
    assert_includes cmd.payload, "fnameescape('/app/app/a.rb')"
    assert_includes cmd.payload, "Gitsigns diffthis"
    assert_includes cmd.payload, "shellescape('HEAD:app/a.rb', 1)"
    calls = capturing(res) { run_command(cmd) }
    assert_equal "--remote-expr", calls.first[0][3]
  end
end
