# frozen_string_literal: true

require "test_helper"
require "socket"
require "tmpdir"
require "io/wait"

module AcpTestHelpers
  SID = "0199f3b7-02aa-7c55-a0e1-9d8c7b6a5f40"

  # Collects what commands put, enforcing the shareability the runtime enforces.
  class Outlet
    def initialize = @queue = Queue.new

    def put(msg)
      raise "not Ractor-shareable: #{msg.inspect}" unless Ractor.shareable?(msg)

      @queue << msg
    end

    def drain
      msgs = []
      msgs << @queue.pop until @queue.empty?
      msgs
    end

    # Pop until a message matches (others are returned too, in order).
    def wait_for(timeout: 5)
      seen = []
      deadline = Time.now + timeout
      loop do
        left = deadline - Time.now
        raise "timed out; saw #{seen.map { it.class.name.split('::').last }}" if left <= 0

        msg = @queue.pop(timeout: left)
        next unless msg

        seen << msg
        return seen if yield(msg)
      end
    end
  end

  class Token
    def initialize = @canceled = false
    def cancel! = @canceled = true
    def canceled? = @canceled
  end

  def log_lines = fixture("acp", "session.jsonl").lines
  def log_entries = log_lines.filter_map { Wt::Acp.parse(it) }

  def update(kind, **fields) = Wt::Msg::AcpUpdate.new(slug: "tasks", update: { "sessionUpdate" => kind, **fields.transform_keys(&:to_s) }, at: Time.at(1))
  def fold(session, *msgs) = msgs.reduce(session) { |s, m| Wt::Acp::Reducer.apply(s, m) }
  def blank = Wt::AgentSession.new(slug: "tasks")

  def line_from(io, timeout: 2)
    raise "nothing was written to the socket" unless io.wait_readable(timeout)

    io.gets
  end

  def connected(m = model(selected: "tasks"), **fields)
    s = Wt::AgentSession.new(slug: "tasks", connection: :connected, session_id: SID, **fields)
    m.put(:sessions, "tasks", Ractor.make_shareable(s))
  end

  def permission_params(id = "toolu_1")
    { "sessionId" => SID, "toolCall" => { "toolCallId" => id, "title" => "`bin/rails db:migrate`", "kind" => "execute", "status" => "pending" },
      "options" => [{ "optionId" => "allow", "name" => "Allow", "kind" => "allow_once" },
                    { "optionId" => "allow_always", "name" => "Always Allow", "kind" => "allow_always" },
                    { "optionId" => "reject", "name" => "Reject", "kind" => "reject_once" }] }
  end

  def with_permission(m = connected, request_id: 5)
    step(m, Wt::Msg::PermissionRequested.new(slug: "tasks", request_id:, params: Ractor.make_shareable(permission_params), at: Time.at(1))).first
  end

  # The payloads a command would write: Acp::Send (possibly inside a batch).
  def sends(cmd)
    cmds = cmd.is_a?(Rooibos::Command::Batch) ? cmd.commands : [cmd]
    cmds.grep(Wt::Acp::Send).flat_map { it.payload.is_a?(Array) ? it.payload : [it.payload] }
  end

  # Session contents without timestamps or connection, for replay ⇔ live comparisons.
  def comparable(s)
    { session_id: s.session_id, running: s.running, stop_reason: s.stop_reason,
      transcript: s.transcript.map { [it.role, it.text, it.tool_call_id] },
      tool_calls: s.tool_calls.map { it.to_h.except(:at) },
      plan: s.plan.map(&:to_h), permission: s.permission&.to_h }
  end
end

class AcpReducerTest < Minitest::Test
  include AcpTestHelpers

  def test_chunks_of_one_role_concatenate_and_a_new_role_starts_an_entry
    s = fold(blank,
             update("agent_thought_chunk", content: { "type" => "text", "text" => "Look at " }),
             update("agent_thought_chunk", content: { "type" => "text", "text" => "the model." }),
             update("agent_message_chunk", content: { "type" => "text", "text" => "Adding " }),
             update("agent_message_chunk", content: { "type" => "text", "text" => "a column." }))
    assert_equal [[:thought, "Look at the model."], [:agent, "Adding a column."]], s.transcript.map { [it.role, it.text] }
  end

  def test_a_tool_call_between_chunks_splits_the_message
    s = fold(blank,
             update("agent_message_chunk", content: { "type" => "text", "text" => "first" }),
             update("tool_call", toolCallId: "t1", title: "Read app/models/task.rb", kind: "read", status: "pending"),
             update("agent_message_chunk", content: { "type" => "text", "text" => "second" }))
    assert_equal [[:agent, "first", nil], [:tool, "Read app/models/task.rb", "t1"], [:agent, "second", nil]],
                 s.transcript.map { [it.role, it.text, it.tool_call_id] }
  end

  def test_tool_call_update_merges_only_the_fields_it_carries
    s = fold(blank,
             update("tool_call", toolCallId: "t1", title: "Edit app/models/task.rb", kind: "edit", status: "in_progress",
                                 locations: [{ "path" => "/ws/tasks/app/models/task.rb", "line" => 12 }]),
             update("tool_call_update", toolCallId: "t1", status: "completed",
                                        content: [{ "type" => "diff", "path" => "/ws/tasks/app/models/task.rb", "oldText" => "a\n", "newText" => "b\n" }]))
    assert_equal 1, s.tool_calls.size
    call = s.tool_calls.first
    assert_equal "Edit app/models/task.rb", call.title
    assert_equal "edit", call.kind
    assert_equal :completed, call.status
    assert_equal [{ path: "/ws/tasks/app/models/task.rb", line: 12 }], call.locations
    assert_equal({ path: "/ws/tasks/app/models/task.rb", old_text: "a\n", new_text: "b\n" }, call.diff)
    assert_equal 1, s.transcript.count { it.role == :tool }, "an update must not add a second transcript entry"
  end

  def test_tool_call_content_text_becomes_output_and_several_diffs_a_list
    s = fold(blank,
             update("tool_call", toolCallId: "t1", title: "Run tests", kind: "execute", status: "in_progress"),
             update("tool_call_update", toolCallId: "t1", status: "failed",
                                        content: [{ "type" => "content", "content" => { "type" => "text", "text" => "1 failure" } }]),
             update("tool_call", toolCallId: "t2", title: "Edit two files", kind: "edit"),
             update("tool_call_update", toolCallId: "t2", content: [{ "type" => "diff", "path" => "/a", "newText" => "x" },
                                                                    { "type" => "diff", "path" => "/b", "oldText" => "y", "newText" => "z" }]))
    assert_equal :failed, s.tool_calls[0].status
    assert_equal "1 failure", s.tool_calls[0].output
    assert_equal %w[/a /b], s.tool_calls[1].diff.map { it[:path] }
    assert_nil s.tool_calls[1].diff.first[:old_text], "a new file has no old text"
  end

  def test_plan_replaces_the_previous_plan
    s = fold(blank,
             update("plan", entries: [{ "content" => "one", "priority" => "high", "status" => "pending" },
                                      { "content" => "two", "priority" => "low", "status" => "pending" }]),
             update("plan", entries: [{ "content" => "one", "priority" => "high", "status" => "completed" }]))
    assert_equal [Wt::PlanEntry.new(content: "one", status: :completed, priority: :high)], s.plan
    assert_equal 1, s.plan_done
  end

  def test_unknown_and_malformed_updates_leave_the_session_alone
    s = fold(blank, update("available_commands_update", availableCommands: []), update("current_mode_update", currentModeId: "plan"),
             update("tool_call_update", status: "failed"), Wt::Msg::AcpUpdate.new(slug: "tasks", update: nil, at: nil),
             update("something_from_a_newer_protocol", foo: 1))
    assert_equal comparable(blank), comparable(s)
  end

  def test_prompt_marks_running_and_stop_reason_clears_it
    s = fold(blank, Wt::Msg::AcpSent.new(slug: "tasks", name: "session/prompt", params: { "prompt" => [{ "type" => "text", "text" => "hi" }] }))
    assert s.running
    assert_equal [[:user, "hi"]], s.transcript.map { [it.role, it.text] }
    s = fold(s, Wt::Msg::AcpResponse.new(slug: "tasks", name: "session/prompt", result: { "stopReason" => "cancelled" }))
    refute s.running
    assert_equal "cancelled", s.stop_reason
  end

  def test_prompt_error_stops_running_and_says_why
    s = fold(blank, Wt::Msg::AcpSent.new(slug: "tasks", name: "session/prompt", params: { "prompt" => [] }),
             Wt::Msg::AcpResponse.new(slug: "tasks", name: "session/prompt", error: { "code" => -32_603, "message" => "Internal error" }))
    refute s.running
    assert_equal "Internal error", s.error
    assert_equal "error: Internal error", s.transcript.last.text
  end

  def test_session_new_result_replaces_the_transcript
    s = fold(blank, update("agent_message_chunk", content: { "type" => "text", "text" => "old" }),
             Wt::Msg::AcpResponse.new(slug: "tasks", name: "session/new", result: { "sessionId" => "s2" }, at: Time.at(9)))
    assert_equal "s2", s.session_id
    assert_empty s.transcript
    assert_equal Time.at(9), s.started_at
  end

  def test_permission_request_and_resolution
    s = fold(blank, Wt::Msg::PermissionRequested.new(slug: "tasks", request_id: 3, params: permission_params))
    assert_equal 3, s.permission.request_id
    assert_equal "`bin/rails db:migrate`", s.permission.title
    assert_equal %w[allow allow_always reject], s.permission.options.map { it[:id] }
    assert_equal ["toolu_1"], s.tool_calls.map(&:id), "the permission's tool call is shown as a tool call"
    assert_equal s, fold(s, Wt::Msg::PermissionResolved.new(slug: "tasks", request_id: 99)), "another request's answer"
    assert_nil fold(s, Wt::Msg::PermissionResolved.new(slug: "tasks", request_id: 3)).permission
  end

  def test_sessions_are_shareable
    s = fold(blank, update("tool_call", toolCallId: "t1", title: "x", locations: [{ "path" => "/a", "line" => 1 }]))
    assert Ractor.shareable?(s)
  end
end

class AcpReplayTest < Minitest::Test
  include AcpTestHelpers

  def test_replay_starts_at_the_last_session_marker
    r = Wt::Acp::Replay.call("tasks", log_lines)
    assert_equal SID, r.session_id
    refute(r.session.transcript.any? { it.text.include?("old") }, "the previous session's transcript leaked in")
    assert_equal "Add a due date to tasks and show overdue ones first", r.session.transcript.first.text
  end

  def test_replay_rebuilds_plan_tool_calls_and_the_unanswered_permission
    s = Wt::Acp::Replay.call("tasks", log_lines).session
    assert_equal [:completed, :completed, :in_progress], s.plan.map(&:status)
    assert_equal %i[completed completed failed pending], s.tool_calls.map(&:status)
    assert_equal "ActiveRecord::PendingMigrationError: Migrations are pending.", s.tool_calls[2].output
    assert_equal [{ path: "/ws/tasks/app/models/task.rb", line: 12 }], s.tool_calls[1].locations
    assert_equal 1, s.permission.request_id, "the answered permission (id 0) must not come back"
    assert s.running, "the second prompt has no stopReason yet"
    assert_equal ["I'll add a migration first.", "The test run needs the migration applied."], s.transcript.select { it.role == :agent }.map(&:text)
  end

  def test_session_load_restarts_the_transcript_because_the_agent_replays_it
    lines = log_lines + [
      %({"ts":"2026-10-20T10:00:00Z","dir":"bridge","event":"session","sessionId":"#{SID}"}),
      %({"ts":"2026-10-20T10:00:00Z","dir":"in","msg":{"jsonrpc":"2.0","id":"wt-9-1","method":"session/load","params":{"sessionId":"#{SID}","cwd":"/ws/tasks","mcpServers":[]}}}),
      %({"ts":"2026-10-20T10:00:01Z","dir":"out","msg":{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"#{SID}","update":{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Run the migration"}}}}})
    ]
    s = Wt::Acp::Replay.call("tasks", lines).session
    assert_equal [[:user, "Run the migration"]], s.transcript.map { [it.role, it.text] }
  end

  def test_missing_or_garbage_log_gives_an_empty_session
    assert_empty Wt::Acp::Replay.read("tasks", "/nonexistent/session.jsonl").session.transcript
    r = Wt::Acp::Replay.call("tasks", ["not json\n", "[1,2]\n", %({"dir":"out","msg":"nope"}\n)])
    assert_nil r.session_id
    assert_empty r.session.transcript
  end

  # Driving the same traffic live — out lines through a Connection, in lines through
  # the actions the person would use — must build the same session as the replay.
  def test_replay_equals_live
    a, b = UNIXSocket.pair
    out = Outlet.new
    conn = Wt::Acp::Connection.new(slug: "tasks", socket: a, config: config, out:)
    Wt::Acp::Registry.register("tasks", conn)
    m = connected
    ids = {} # logged id → the id this connection gave the same request
    entries = log_lines
    start = entries.rindex { it.include?('"event":"session"') }
    entries[(start + 1)..].each do |line|
      e = Wt::Acp.parse(line)
      next conn.handle(line[/"msg":(.*)\}$/, 1].to_s) unless e # truncated line: the wire can be broken too

      msg = e["msg"]
      if e["dir"] == "in" && msg["method"] == "session/prompt"
        m = m.with(ui: m.ui.with(input: msg.dig("params", "prompt", 0, "text")))
        m, cmd = Wt::Actions.send_input(m)
        cmd.call(out, Token.new)
        ids[msg["id"]] = JSON.parse(line_from(b))["id"]
      elsif e["dir"] == "in" && !msg["method"]
        key = (m.permission_for("tasks").options.index { it[:id] == msg.dig("result", "outcome", "optionId") } + 1).to_s
        m, cmd = step(m, key)
        cmd.call(out, Token.new)
        assert_equal msg["result"], JSON.parse(line_from(b))["result"]
      elsif e["dir"] == "out"
        msg = msg.merge("id" => ids.fetch(msg["id"])) if !msg["method"] && msg.key?("id")
        conn.handle(JSON.generate(msg))
      end
      m, = step(m, *out.drain)
    end
    assert_equal comparable(Wt::Acp::Replay.call("tasks", log_lines).session), comparable(m.sessions["tasks"])
  ensure
    Wt::Acp::Registry.clear
    [a, b].each { it&.close }
  end
end

class AcpActionsTest < Minitest::Test
  include AcpTestHelpers

  def test_answer_maps_1_2_3_to_the_options_in_the_order_sent
    %w[allow allow_always reject].each_with_index do |option, i|
      m, cmd = step(with_permission, (i + 1).to_s)
      assert_nil m.permission_for("tasks")
      assert_equal [{ "id" => 5, "result" => { "outcome" => { "outcome" => "selected", "optionId" => option } } }], sends(cmd)
    end
  end

  def test_digits_without_a_pending_permission_change_nothing
    m = connected
    m2, cmd = step(m, "1")
    assert_equal m, m2
    assert_nil cmd
  end

  def test_typed_reply_rejects_then_prompts
    m = with_permission
    m = m.with(ui: m.ui.with(input: "use db:prepare instead", input_focus: true))
    m, cmd = step(m, "enter")
    payloads = sends(cmd)
    assert_equal({ "id" => 5, "result" => { "outcome" => { "outcome" => "selected", "optionId" => "reject" } } }, payloads[0])
    assert_equal "session/prompt", payloads[1]["method"]
    assert_equal({ "sessionId" => SID, "prompt" => [{ "type" => "text", "text" => "use db:prepare instead" }] }, payloads[1]["params"])
    refute payloads[1].key?("id"), "the connection assigns request ids"
    assert_equal 2, payloads.size, "one Send keeps the reject before the prompt"
    s = m.sessions["tasks"]
    assert_nil s.permission
    assert s.running
    assert_equal [:user, "use db:prepare instead"], [s.transcript.last.role, s.transcript.last.text]
    assert_equal "", m.ui.input
  end

  def test_digits_typed_into_a_reply_are_text_not_answers
    m = with_permission
    m = m.with(ui: m.ui.with(input: "step ", input_focus: true))
    m, cmd = step(m, "2")
    assert_equal "step 2", m.ui.input
    refute_nil m.permission_for("tasks")
    assert_nil cmd
  end

  def test_empty_input_sends_nothing
    m = connected
    m = m.with(ui: m.ui.with(input: "   "))
    assert_equal m, Wt::Actions.send_input(m)
  end

  def test_reply_without_a_connection_keeps_the_text_and_says_why
    m = model.with(ui: model.ui.with(selected: "tasks", input: "hello"))
    m, = Wt::Actions.send_input(m)
    assert_equal "hello", m.ui.input
    assert_match(/not connected/, m.ui.toasts.last.text)
  end

  def test_chat_without_an_agent_starts_the_unit_and_shows_connecting
    m, cmd = step(model(selected: "tasks"), "a")
    assert_equal :chat, m.ui.screen
    assert_equal "tasks", m.ui.chat_slug
    assert m.ui.input_focus
    assert_equal :connecting, m.sessions["tasks"].connection
    assert_kind_of Wt::Commands::MiseTask, cmd
    assert_equal %w[agent:up], cmd.args
    assert_equal "/ws/tasks", cmd.cwd
    refute cmd.refresh
  end

  def test_chat_connected_without_a_session_creates_one_in_the_host_path
    m = connected.put(:sessions, "tasks", connected.sessions["tasks"].with(session_id: nil))
    m = m.with(ui: m.ui.with(selected: "tasks"))
    _, cmd = step(m, "a")
    assert_equal [{ "method" => "session/new", "params" => { "cwd" => "/ws/tasks", "mcpServers" => [] } }], sends(cmd)
  end

  def test_chat_with_a_session_just_opens_it
    m = connected.with(ui: connected.ui.with(selected: "tasks"))
    m, cmd = step(m, "a")
    assert_nil cmd
    assert_equal :chat, m.ui.screen
  end

  def test_agent_coming_up_after_a_creates_the_session
    m, = step(model(selected: "tasks"), "a")
    m, cmd = step(m, Wt::Msg::AcpConnection.new(slug: "tasks", state: :connected, agent: "claude-agent-acp"))
    assert_equal :connected, m.sessions["tasks"].connection
    assert_equal ["session/new"], sends(cmd).map { it["method"] }
  end

  def test_agent_reconnecting_on_its_own_waits_for_the_person
    _, cmd = step(model, Wt::Msg::AcpConnection.new(slug: "tasks", state: :connected))
    assert_nil cmd
  end

  def test_new_session_sends_session_new
    m = connected.with(ui: connected.ui.with(selected: "tasks"))
    _, cmd = step(m, "A")
    assert_equal ["session/new"], sends(cmd).map { it["method"] }
  end

  def test_stop_agent_confirms_then_cancels_the_turn_and_stops_the_unit
    m = with_permission(connected(running: true))
    m = m.with(ui: m.ui.with(selected: "tasks"))
    m, cmd = step(m, "K")
    assert_nil cmd
    assert_equal "Stop agent for tasks?", m.ui.confirm.prompt
    m, cmd = step(m, "y")
    assert_equal [{ "method" => "session/cancel", "params" => { "sessionId" => SID } },
                  { "id" => 5, "result" => { "outcome" => { "outcome" => "cancelled" } } }], sends(cmd)
    assert_equal [%w[agent:stop]], cmd.commands.grep(Wt::Commands::MiseTask).map(&:args)
    assert_nil m.permission_for("tasks")
  end

  def test_stop_agent_when_idle_only_stops_the_unit
    m = connected.with(ui: connected.ui.with(selected: "tasks"))
    m, = step(m, "K")
    _, cmd = step(m, "y")
    assert_kind_of Wt::Commands::MiseTask, cmd
    assert_equal %w[agent:stop], cmd.args
  end
end

class AcpNotifyTest < Minitest::Test
  include AcpTestHelpers

  def test_permission_while_unfocused_notifies_the_desktop
    m = connected.with(ui: model.ui.with(focused: false))
    _, cmd = step(m, Wt::Msg::PermissionRequested.new(slug: "tasks", request_id: 1, params: Ractor.make_shareable(permission_params)))
    assert_kind_of Wt::Acp::Notify, cmd
    assert_equal ["notify-send", "-a", "wt", "wt: tasks: permission needed", "`bin/rails db:migrate`"], cmd.argv
  end

  def test_no_notification_while_focused
    _, cmd = step(connected, Wt::Msg::PermissionRequested.new(slug: "tasks", request_id: 1, params: Ractor.make_shareable(permission_params)))
    assert_nil cmd
  end

  def test_a_held_permission_resent_on_reconnect_does_not_notify_twice
    m = with_permission(connected.with(ui: model.ui.with(focused: false)), request_id: 1)
    _, cmd = step(m, Wt::Msg::PermissionRequested.new(slug: "tasks", request_id: 1, params: Ractor.make_shareable(permission_params)))
    assert_nil cmd
  end

  def test_failed_tool_call_while_unfocused_notifies_once
    m = connected.with(ui: model.ui.with(focused: false))
    m, = step(m, update("tool_call", toolCallId: "t1", title: "Run tests", kind: "execute", status: "in_progress"))
    m, cmd = step(m, update("tool_call_update", toolCallId: "t1", status: "failed"))
    assert_equal "wt: tasks: tool call failed", cmd.argv[3]
    _, cmd = step(m, update("tool_call_update", toolCallId: "t1", content: []))
    assert_nil cmd, "already failed"
  end

  def test_missing_notify_send_is_silent
    out = Outlet.new
    Wt::Acp::Notify.new(argv: ["wt-no-such-notify-send", "x"], timeout: 1).call(out, Token.new)
    assert_empty out.drain
  end
end

# Watch against a fake acp-bridge on a temp unix socket.
class AcpWatchTest < Minitest::Test
  include AcpTestHelpers

  def setup
    @root = Dir.mktmpdir("wt-acp")
    %w[tasks other .run/tasks .run/other].each { FileUtils.mkdir_p(File.join(@root, it)) }
    FileUtils.cp(fixture_path("acp", "session.jsonl"), File.join(@root, ".run/tasks/session.jsonl"))
    @config = config(root: @root)
    @out = Outlet.new
    @token = Token.new
    @threads = []
  end

  def teardown
    @token.cancel!
    @watch_thread&.join(3)
    @threads.each { it.kill }
    Wt::Acp::Registry.clear
    FileUtils.rm_rf(@root)
  end

  def start_watch
    @watch_thread = Thread.new { Wt::Acp::Watch.new(config: @config).call(@out, @token) }
  end

  def bridge(slug, &block)
    server = UNIXServer.new(@config.acp_socket(slug))
    @threads << Thread.new { block.call(server) }
    server
  end

  def test_connect_replay_held_permission_busy_prompt_and_end
    client_ready = Queue.new
    close_client = Queue.new
    requests = Queue.new
    tasks = bridge("tasks") do |server|
      c = server.accept
      c.write(fixture("acp", "hello.json"))
      # The held permission (id 1 in the log) is re-sent right after hello.
      held = Wt::Acp.parse(fixture("acp", "session.jsonl").lines.last)["msg"]
      c.write("#{JSON.generate(held)}\n")
      c.write("garbage that is not json\n")
      init = JSON.parse(c.gets)
      requests << init
      c.write("#{JSON.generate({ jsonrpc: '2.0', id: init['id'], result: JSON.parse(fixture('acp', 'initialize_result.json')) })}\n")
      client_ready << true
      prompt = JSON.parse(c.gets)
      requests << prompt
      c.write("#{JSON.generate({ jsonrpc: '2.0', id: prompt['id'], result: { stopReason: 'end_turn' } })}\n")
      close_client.pop
      c.close
    end
    bridge("other") do |server|
      loop do
        c = server.accept
        c.write(fixture("acp", "busy.json"))
        c.close
      end
    end
    start_watch

    seen = @out.wait_for { it.is_a?(Wt::Msg::AcpConnection) && it.slug == "tasks" && it.state == :connected }
    seen += @out.wait_for { it.is_a?(Wt::Msg::AcpConnection) && it.slug == "other" } unless seen.any? { it.is_a?(Wt::Msg::AcpConnection) && it.slug == "other" }
    m, = step(model(worktrees: [worktree("tasks"), worktree("other", id: 2)]), *seen)

    init = requests.pop
    assert_equal "initialize", init["method"]
    assert_match(/\Awt-\h{8}-\d+\z/, init["id"])
    assert_equal({ "fs" => { "readTextFile" => false, "writeTextFile" => false }, "terminal" => false }, init.dig("params", "clientCapabilities"))

    s = m.sessions["tasks"]
    assert_equal :connected, s.connection
    assert_equal SID, s.session_id, "hello's session is reused, no session/new"
    assert_equal "claude-agent-acp", s.agent
    assert_equal "Add a due date to tasks and show overdue ones first", s.transcript.first.text, "transcript rebuilt from session.jsonl"
    assert_equal 1, s.permission.request_id, "held permission delivered after connect"

    other = m.sessions["other"]
    assert_equal :busy, other.connection
    assert_equal "in use by pid 48213 uid 1000, connected 2026-10-20T09:10:44Z", other.transcript.last.text
    refute_equal :failed, m.agent_state("other"), "busy is not a failure"

    client_ready.pop
    Wt::Acp.send_to("tasks", Wt::Acp.request("session/prompt", Wt::Acp.prompt_params(SID, "go"))).call(@out, @token)
    prompt = requests.pop
    assert_equal init["id"].sub(/\d+\z/, "2"), prompt["id"], "ids count up on one connection"
    resp = @out.wait_for { it.is_a?(Wt::Msg::AcpResponse) }.last
    assert_equal ["session/prompt", { "stopReason" => "end_turn" }], [resp.name, resp.result]

    close_client << true
    ended = @out.wait_for { it.is_a?(Wt::Msg::AcpConnection) && it.slug == "tasks" }.last
    assert_equal :ended, ended.state
    m, = step(m, ended)
    assert_equal "session ended", m.sessions["tasks"].transcript.last.text
    assert_equal :offline, m.agent_state("tasks")

    tasks.close
    File.unlink(@config.acp_socket("tasks"))
    gone = @out.wait_for { it.is_a?(Wt::Msg::AcpConnection) && it.slug == "tasks" }.last
    assert_equal :disconnected, gone.state
  end

  def test_reconnects_when_the_socket_comes_back_and_loads_the_logged_session
    load = Queue.new
    first = bridge("tasks") do |server|
      c = server.accept
      c.write(fixture("acp", "hello.json"))
      init = JSON.parse(c.gets)
      c.write("#{JSON.generate({ jsonrpc: '2.0', id: init['id'], result: {} })}\n")
      c.close
    end
    start_watch
    @out.wait_for { it.is_a?(Wt::Msg::AcpConnection) && it.state == :ended }
    first.close
    File.unlink(@config.acp_socket("tasks"))

    # The unit restarted: a fresh adapter without a session, which supports session/load.
    bridge("tasks") do |server|
      c = server.accept
      hello = JSON.parse(fixture("acp", "hello.json"))
      hello["params"].merge!("sessionId" => nil, "initialized" => false, "initializeResult" => nil, "pending" => 0)
      c.write("#{JSON.generate(hello)}\n")
      init = JSON.parse(c.gets)
      c.write("#{JSON.generate({ jsonrpc: '2.0', id: init['id'], result: JSON.parse(fixture('acp', 'initialize_result.json')) })}\n")
      req = JSON.parse(c.gets)
      load << req
      c.write("#{JSON.generate({ jsonrpc: '2.0', id: req['id'], result: {} })}\n")
      sleep 5
    end
    seen = @out.wait_for { it.is_a?(Wt::Msg::AcpConnection) && it.state == :connected }
    req = load.pop
    assert_equal "session/load", req["method"]
    assert_equal({ "sessionId" => SID, "cwd" => File.join(@root, "tasks"), "mcpServers" => [] }, req["params"])
    assert_equal SID, seen.last.session_id
    replayed = seen.grep(Wt::Msg::AcpReplayed).last
    assert_nil replayed.session.permission, "the bridge holds nothing, so the logged permission is stale"
  end
end
