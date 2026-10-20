# frozen_string_literal: true

require "test_helper"

class AgentViewsTest < Minitest::Test
  NOW = Time.at(1_800_000_000)
  PERM_OPTIONS = [
    { id: "allow", name: "Allow once", kind: "allow_once" },
    { id: "always", name: "Always allow bin/rails db:*", kind: "allow_always" },
    { id: "reject", name: "Reject", kind: "reject_once" }
  ].freeze

  def theme = Wt::Theme.for(:light)

  # Draw a bare widget into a test terminal and return the screen text.
  def draw(width, height)
    out = nil
    with_test_terminal(width, height) do
      widget = yield RatatuiRuby::TUI.new
      RatatuiRuby.draw { |f| f.render_widget(widget, f.area) }
      out = buffer_content.join("\n")
    end
    out
  end

  def call(id, kind, title, status: :completed, path: nil, diff: nil, at: NOW - 60)
    Wt::ToolCall.new(id:, kind:, title:, status:, locations: path ? [{ path:, line: 14 }] : [], diff:, at:)
  end

  def session(slug, permission: nil, connection: :connected, running: true, **)
    Wt::AgentSession.new(
      slug:, agent: "claude-agent-acp", session_id: "s1", connection:, running:, started_at: NOW - 900,
      plan: [Wt::PlanEntry.new(content: "Read BucketCounts query", status: :completed),
             Wt::PlanEntry.new(content: "Badge counts", status: :completed),
             Wt::PlanEntry.new(content: "Component tests", status: :completed),
             Wt::PlanEntry.new(content: "Index on status_bucket", status: :in_progress),
             Wt::PlanEntry.new(content: "System tests", status: :pending)],
      tool_calls: [call("t1", "read", "Read bucket_counts.rb", path: "/ws/tasks/app/queries/bucket_counts.rb"),
                   call("t2", "edit", "Edit filter_sidebar", path: "/ws/tasks/app/components/filter_sidebar.rb",
                                                             diff: { path: "/ws/tasks/app/components/filter_sidebar.rb", old_text: "a\nold line\nc", new_text: "a\nnew line\nc" }),
                   call("t3", "execute", "bin/rails db:migrate", status: :pending)],
      transcript: [Wt::TranscriptEntry.new(role: :user, text: "Wire the bucket counts"),
                   Wt::TranscriptEntry.new(role: :agent, text: "BucketCounts lives on the parent branch."),
                   Wt::TranscriptEntry.new(role: :tool, tool_call_id: "t1"),
                   Wt::TranscriptEntry.new(role: :tool, tool_call_id: "t2"),
                   Wt::TranscriptEntry.new(role: :agent, text: "I added an index migration and want to apply it."),
                   Wt::TranscriptEntry.new(role: :tool, tool_call_id: "t3")],
      permission:, **
    )
  end

  def permission = Wt::Permission.new(request_id: "r1", tool_call_id: "t3", title: "claude asks to run a command", options: PERM_OPTIONS)

  def with_session(m, slug, s) = m.put(:sessions, slug, s)

  # --- Session ---------------------------------------------------------------

  def test_session_panel_shows_plan_tool_calls_permission_and_input
    m = with_session(model(width: 187), "tasks", session("tasks", permission:))
    out = draw(150, 20) { |tui| Wt::Views::Session.panel(m, tui, theme, "tasks") }
    assert_includes out, "plan · 3 of 5"
    assert_includes out, "[x] Read BucketCounts query"
    assert_includes out, "[~] Index on status_bucket"
    assert_includes out, "[ ] System tests"
    assert_includes out, "follow ●"
    assert_match(/✎ edit\s+Edit filter_sidebar/, out)
    assert_match(/\$ execute\s+bin\/rails db:migrate.*◐ pending/, out)
    assert_includes out, "◆ Permission claude asks to run a command"
    assert_match(/1 +Allow once +2 +Always allow bin\/rails db:\* +3 +Reject/, out)
    assert_includes out, "› Answer with 1-3"
    assert_includes out, "⏎ send · a full chat"
    assert_includes out, "◇ I added an index migration"
  end

  def test_session_panel_selected_tool_call_shows_hint_and_drops_follow
    m = with_session(model(width: 187, tool_index: 1, input: "hold on", input_focus: true), "tasks", session("tasks"))
    out = draw(150, 14) { |tui| Wt::Views::Session.panel(m, tui, theme, "tasks") }
    refute_includes out, "follow ●"
    assert_match(/Edit filter_sidebar.*o nvim · d diff/, out)
    refute_match(/db:migrate/, out, "window ends at the selected call")
    assert_includes out, "› hold on▏"
    refute_includes out, "Permission"
  end

  def test_session_panel_without_acp_shows_status_file_state
    m = model(width: 187).put(:agents, "tasks", Wt::AgentStatus.new(state: :waiting, agent: "claude", last: "Edit app/x.rb"))
    out = draw(100, 8) { |tui| Wt::Views::Session.panel(m, tui, theme, "tasks") }
    assert_includes out, "· waiting for you"
    assert_includes out, "Edit app/x.rb"
    assert_includes out, "start a chat"
    m = model(width: 187).put(:agents, "tasks", Wt::AgentStatus.new(state: :working))
    assert_includes draw(100, 8) { |tui| Wt::Views::Session.panel(m, tui, theme, "tasks") }, "● working"
    m = model(width: 187).put(:agents, "tasks", Wt::AgentStatus.new(state: :offline))
    assert_includes draw(100, 8) { |tui| Wt::Views::Session.panel(m, tui, theme, "tasks") }, "○ offline"
  end

  def test_session_title
    m = with_session(model, "tasks", session("tasks"))
    text = draw(100, 1) { |tui| tui.paragraph(text: [tui.line(spans: Wt::Views::Session.title(m, tui, theme, "tasks"))]) }
    assert_includes text, "Agent claude-agent-acp · session 15m"
    m = model.put(:agents, "tasks", Wt::AgentStatus.new(state: :working, agent: "claude"))
    text = draw(100, 1) { |tui| tui.paragraph(text: [tui.line(spans: Wt::Views::Session.title(m, tui, theme, "tasks"))]) }
    assert_includes text, "Agent claude · ● working"
    refute_includes text, "session"
  end
  # --- Agents ------------------------------------------------------------------

  # 10 agents: 2 permission (ACP), 1 failed, 4 running, 3 done (status files), in a scrambled list order.
  STATES = %i[waiting working permission failed working waiting permission working working waiting].freeze

  def ten_agents(**ui)
    wts = STATES.each_index.map { worktree("wt#{it}", id: it + 1) }
    m = model(worktrees: wts, **ui)
    STATES.each_with_index do |st, i|
      slug = "wt#{i}"
      m = if st == :permission
            m.put(:sessions, slug, session(slug, permission:))
          else
            m.put(:agents, slug, Wt::AgentStatus.new(state: st, agent: "claude", last: "last of #{slug}"))
          end
    end
    m
  end

  def test_cards_half_three_across_two_rows_rest_as_rows
    out = render(ten_agents(screen: :agents, width: 140))
    first_row = out.lines.find { it.include?("┌") && it.include?("^1") }
    assert_equal %w[^1 ^2 ^3], first_row.scan(/\^\d+/)
    assert_equal %w[^4 ^5 ^6], out.lines.find { it.include?("┌") && it.include?("^4") }.scan(/\^\d+/)
    assert_includes out, "+4 more"
    %w[^7 ^8 ^9].each { |k| assert(out.lines.any? { it.include?(k) && !it.include?("┌") }, "#{k} as one-line row") }
    assert_includes out, "Agents 10 · 2 need input · 1 failed · 4 running · 3 done"
  end

  def test_cards_twothirds_four_across_and_full_six_across
    out = render(ten_agents(screen: :agents, width: 187))
    assert_equal %w[^1 ^2 ^3 ^4], out.lines.find { it.include?("┌") && it.include?("^1") }.scan(/\^\d+/)
    assert_includes out, "+2 more"
    assert_includes out, "Agents 10 · 2 need input"
    out = render(ten_agents(screen: :agents, width: 282))
    assert_equal %w[^1 ^2 ^3 ^4 ^5 ^6], out.lines.find { it.include?("┌") && it.include?("^1") }.scan(/\^\d+/)
    assert_equal %w[^7 ^8 ^9], out.lines.find { it.include?("┌") && it.include?("^7") }.scan(/\^\d+/)
    refute_includes out, "more ·"
  end

  def test_cards_order_by_urgency_with_state_and_plan
    out = render(ten_agents(screen: :agents, width: 187))
    first = out.lines.find { it.include?("┌") && it.include?("^1") }
    assert_match(/\^1 wt2 .*\^2 wt6 .*\^3 wt3 .*\^4 wt1/, first)
    assert_includes out, "◆ PERMISSION"
    assert_includes out, "✗ FAILED"
    assert_includes out, "● RUNNING"
    assert_includes out, "plan  ▰▰▰▱▱ 3/5"
    assert_includes out, "◆ claude asks to run a command  1-3"
  end

  def test_needs_attention_lists_permissions_with_options
    out = render(ten_agents(screen: :agents, width: 187))
    assert_includes out, "Needs attention 3"
    assert_match(/1 +Allow once +2 +Always allow bin\/rails db:\* +3 +Reject/, out)
    assert_match(/◆ \^1 wt2/, out)
    assert_match(/✗ \^3 wt3/, out)
  end

  def test_list_view_one_row_per_agent
    out = render(ten_agents(screen: :agents, width: 187, agents_view: :list, agents_index: 2))
    refute(out.lines.any? { it.include?("┌") && it.include?("^1") }, "no cards")
    rows = out.lines.select { it.match?(/\^\d+ +[◆✗●·○] /) }
    assert_equal 9, rows.size
    assert_match(/▌ \^3 +✗ failed +wt3/, out)
    assert(out.lines.any? { it.match?(/· done +wt9/) }, "10th agent listed without ^ label")
    assert_includes out, "Agents 10 · 2 need input · 1 failed · 4 running · 3 done"
  end

  def test_compact_is_list_only
    out = render(ten_agents(screen: :agents, width: 90, agents_view: :cards))
    refute(out.lines.any? { it.include?("┌") && it.include?("^1 wt") }, "compact draws no cards")
    assert_match(/\^1 +◆ permission +wt2/, out)
    refute_includes out, "Session updates"
  end

  # --- Chat ------------------------------------------------------------------

  def chat_model(**ui)
    m = model(screen: :chat, chat_slug: "tasks", **ui)
    m.put(:sessions, "tasks", session("tasks", permission:))
     .put(:services, "tasks", [Wt::Service.new(name: "rails", state: :running, port: 3014), Wt::Service.new(name: "db", state: :stopped)])
     .put(:nvim, "tasks", Wt::NvimStatus.new(running: true, ui_count: 1, buffers: 7, modified: 1))
  end

  def test_chat_twothirds_has_sidebar_and_transcript
    out = render(chat_model(width: 187))
    assert_includes out, "wt/tasks"
    assert_includes out, "Services"
    assert_match(/postgres +○ stopped/, out)
    assert_match(/rails +● :3014/, out)
    assert_includes out, "Changes"
    assert_includes out, "✎ app/components/filter_sidebar.rb"
    assert_includes out, "› Wire the bucket counts"
    assert_includes out, "◇ BucketCounts lives on the parent branch."
    assert_match(/✓ ◇ read +Read bucket_counts.rb  app\/queries\/bucket_counts.rb:14/, out)
    assert_includes out, "- old line"
    assert_includes out, "+ new line"
    refute_includes out, "services 1/2 up"
    out = render(step(chat_model(width: 187), "ctrl+b").first)
    refute_includes out, "Changes"
  end

  def test_chat_half_has_strip_and_sidebar_on_ctrl_b
    m = chat_model(width: 140)
    out = render(m)
    assert_includes out, "services 1/2 up"
    refute_includes out, "Changes"
    out = render(step(m, "ctrl+b").first)
    assert_includes out, "Changes"
    refute_includes out, "services 1/2 up"
  end

  def test_chat_compact_transcript_only_context_on_ctrl_b
    m = chat_model(width: 90)
    out = render(m)
    refute_includes out, "services 1/2 up"
    refute_includes out, "Changes"
    assert_includes render(step(m, "ctrl+b").first), "services 1/2 up"
  end

  def test_chat_permission_options_in_order
    out = render(chat_model(width: 187))
    assert_match(/1 +Allow once +2 +Always allow bin\/rails db:\* +3 +Reject/, out)
    assert_includes out, "› Answer with 1-3"
  end

  def test_chat_selected_tool_call_shows_hint
    out = render(chat_model(width: 187, tool_index: 1))
    assert_match(/Edit filter_sidebar.*o open in nvim · d diff/, out)
  end

  def test_chat_states_without_live_session
    out = render(model(screen: :chat, chat_slug: "tasks", width: 187))
    assert_includes out, "No agent session for tasks."
    assert_includes out, "start a chat"
    assert_includes out, "mise run agent:up"
    busy = Wt::AgentSession.new(slug: "tasks", connection: :busy, transcript: [Wt::TranscriptEntry.new(role: :system, text: "in use by pid 4242")])
    out = render(model(screen: :chat, chat_slug: "tasks", width: 187).put(:sessions, "tasks", busy))
    assert_includes out, "socket busy"
    assert_includes out, "pid 4242"
    ended = session("tasks", connection: :ended, running: false)
    out = render(model(screen: :chat, chat_slug: "tasks", width: 187).put(:sessions, "tasks", ended))
    assert_includes out, "session ended"
    assert_match(/A +for a new one/, out)
  end

  def test_plan_bar_clamps_out_of_range_progress
    assert_equal "▰▰▰▰", Wt::Views::Session.bar(7, 4)
    assert_equal "▱▱▱▱", Wt::Views::Session.bar(-2, 4)
    assert_equal "", Wt::Views::Session.bar(3, 0)
  end

  def test_chat_wraps_cjk_by_display_width
    rows = Wt::Views::Chat.wrap("日本語の文章" * 5, 10)
    assert(rows.all? { RatatuiRuby::Text.width(it) <= 10 }, rows.inspect)
    assert_equal "日本語の文章" * 5, rows.join
    assert_equal ["hello", "world foo"], Wt::Views::Chat.wrap("hello world foo", 10)
  end

  def test_chat_wrap_terminates_on_a_grapheme_wider_than_the_row
    cluster = "क#{"्क" * 100}" # one Devanagari conjunct chain: a single grapheme cluster, ~200 cells
    assert_equal 1, cluster.each_grapheme_cluster.count
    rows = Timeout.timeout(2) { Wt::Views::Chat.wrap("hi #{cluster} there", 80) }
    assert_equal ["hi", cluster, "there"], rows
  end
end
