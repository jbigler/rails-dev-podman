# frozen_string_literal: true

require "test_helper"

class DashboardViewTest < Minitest::Test
  TIERS = { compact: 90, half: 140, twothirds: 187, full: 282 }.freeze
  LONG_BRANCH = "intake/questionnaire-model-with-conditional-sections"

  def svc(name, state, port: nil, started: nil)
    Wt::Service.new(name:, state:, port:, started_at: started && Time.at(1_800_000_000 - started))
  end

  # Four worktrees in the states the mockup shows: a stacked branch waiting on a
  # permission, a running agent with pending CI, a long branch name, an idle base.
  def dashboard(width:, **ui)
    wts = [worktree("tasks-filtering", id: 14, branch: "tasks/filter-ui"),
           worktree("hipaa-logoff", id: 3, branch: "hipaa/automatic-logoff"),
           worktree("intake-forms", id: 5, branch: LONG_BRANCH),
           worktree("master", id: 0, branch: "main", base: true)]
    m = model(worktrees: wts, width:, height: 70, **ui)
    m.with(
      git: { "tasks-filtering" => Wt::GitStatus.new(branch: "tasks/filter-ui", ahead: 4, behind: 0, dirty: 4),
             "hipaa-logoff" => Wt::GitStatus.new(branch: "hipaa/automatic-logoff"),
             "intake-forms" => Wt::GitStatus.new(branch: LONG_BRANCH),
             "master" => Wt::GitStatus.new(branch: "main") },
      services: {
        "tasks-filtering" => [svc("rails", :running, port: 13_014, started: 6000), svc("db", :healthy, port: 55_446, started: 6000),
                              svc("redis", :running, started: 6000), svc("rustfs", :starting, port: 19_014, started: 8),
                              svc("playwright", :stopped)],
        "hipaa-logoff" => Wt::Service::NAMES.map { svc(it, :running) },
        "intake-forms" => [svc("rails", :running), svc("db", :failed), svc("redis", :running), svc("rustfs", :running), svc("playwright", :stopped)],
        "master" => Wt::Service::NAMES.map { svc(it, :stopped) }
      },
      stats: { "tasks-filtering" => { "filial-tasks-filtering-rails" => Wt::Stats.new(cpu: 3.8, mem: 627_048_448) } },
      prs: { "tasks-filtering" => Wt::PrStatus.new(number: 1421, title: "Filter sidebar badges with bucket counts", draft: true,
                                                   ci: :fail, ci_passed: 12, ci_failed: 2, ci_total: 14, failing: %w[rubocop system]),
             "hipaa-logoff" => Wt::PrStatus.new(number: 1398, title: "Automatic logoff", ci: :pending, ci_passed: 14, ci_total: 15),
             "intake-forms" => :none, "master" => :none },
      stacks: { "tasks-filtering" => Wt::Stack.new(trunk: "main", needs_restack: true, entries: [
        Wt::StackEntry.new(branch: "tasks/criteria-object", number: 1412, review: :approved, ci: :pass),
        Wt::StackEntry.new(branch: "tasks/bucket-counts", number: 1418, review: :review_required, ci: :pending),
        Wt::StackEntry.new(branch: "tasks/filter-ui", number: 1421, draft: true, ci: :fail, head: true)
      ]), "hipaa-logoff" => Wt::Stack.new, "master" => Wt::Stack.new },
      agents: { "tasks-filtering" => Wt::AgentStatus.new(state: :permission, agent: "claude", last: "permission: bin/rails db:migrate"),
                "hipaa-logoff" => Wt::AgentStatus.new(state: :working, agent: "codex", last: "execute bin/rails test:system") },
      nvim: { "tasks-filtering" => Wt::NvimStatus.new(running: true, ui_count: 1, buffers: 7) },
      log_lines: ["Started GET \"/tasks?bucket=overdue\" for 10.88.0.1", "Completed 200 OK in 418ms"],
      failures: { "stack:intake-forms" => "gh: timeout" }
    )
  end

  def screen(width:, **ui)
    m = dashboard(width:, **ui)
    [m, render(m, width:, height: 70)]
  end

  def row_of(text, slug)
    text.lines.find { it.include?(" #{slug} ") } || flunk("no row for #{slug}:\n#{text}")
  end

  # Text of one list column on a row: the cells under its header label, up to the next label.
  def column(text, label, slug)
    header = text.lines.find { it.include?("WORKTREE") }
    start = header.index(label) or return nil
    stop = header.index(/\S/, start + label.length) || header.size
    row_of(text, slug)[start...stop]
  end

  def test_every_tier_shows_all_worktrees_with_selection_marker
    TIERS.each do |tier, width|
      m, text = screen(width:)
      assert_equal tier, m.ui.tier
      assert_includes text, "Worktrees 4 · 2 agents", tier
      assert_match(/▌ tasks-filtering/, row_of(text, "tasks-filtering"), tier)
      refute_includes row_of(text, "hipaa-logoff"), "▌", tier
      %w[hipaa-logoff intake-forms master].each { assert row_of(text, it), "#{tier}: #{it}" }
    end
  end

  def test_panels_per_tier
    _, compact = screen(width: 90)
    refute_includes compact, "wt/tasks-filtering"
    refute_includes compact, "Pod filial-tasks-filtering"
    refute_includes compact, "Logs"

    %i[half twothirds].each do |tier|
      _, text = screen(width: TIERS[tier])
      assert_includes text, "wt/tasks-filtering", tier
      assert_includes text, "Pod filial-tasks-filtering", tier
      assert_includes text, "Agent claude", tier
      refute_includes text, "Logs ", tier
    end

    _, full = screen(width: 282)
    assert_includes full, "Logs rails · postgres · redis · rustfs · playwright"
    assert_includes full, "Completed 200 OK in 418ms"
  end

  def test_layout_geometry_per_tier
    _, half = screen(width: 140)
    rows = half.lines
    pod = rows.index { it.include?("Pod filial-") }
    stack = rows.index { it.include?("wt/tasks-filtering") }
    agent = rows.index { it.include?("Agent claude") }
    assert stack < pod && pod < agent, "half stacks branch & stack, pod, agent top to bottom"

    _, two = screen(width: 187)
    line = two.lines.find { it.include?("wt/tasks-filtering") }
    assert_includes line, "Pod filial-tasks-filtering", "⅔ puts branch & stack beside the pod"
    assert_operator line.index("Pod"), :>, 90

    _, full = screen(width: 282)
    list_line = full.lines.find { it.include?("Worktrees 4") }
    assert_equal 282 - 112, list_line.index("┌ Agent claude"), "agent column is the right-most 112 cols"
  end

  def test_compact_enter_opens_detail_and_esc_returns_to_list
    m = dashboard(width: 90)
    m, = step(m, "enter")
    assert m.ui.detail
    detail = render(m, width: 90, height: 70)
    assert_includes detail, "wt/tasks-filtering"
    assert_includes detail, "Pod filial-tasks-filtering"
    refute_includes detail, "WORKTREE"

    m, = step(m, "esc")
    back = render(m, width: 90, height: 70)
    assert_includes back, "WORKTREE"
    refute_includes back, "Pod filial-"
  end

  def test_wide_tiers_have_every_column
    [187, 282].each do |width|
      _, text = screen(width:)
      header = text.lines.find { it.include?("WORKTREE") }
      %w[HEAD STACK PR CI SERVICES AGENT NVIM LAST].each { assert_includes header, it, "#{width}: #{it}" }
      row = row_of(text, "tasks-filtering")
      assert_includes row, "#1421"
      assert_includes row, "✗ 2"
      assert_includes row, "●●●◐○"
      assert_includes row, "◆ claude"
      assert_includes row, "● 1"
      assert_includes row, "permission: bin/rails db:migrate"
      assert_includes row_of(text, "hipaa-logoff"), "⟳ 14/15"
      assert_includes row_of(text, "intake-forms"), "no PR"
    end
  end

  def test_narrow_tiers_merge_ci_into_pr_summarise_services_and_drop_nvim
    _, half = screen(width: 140)
    header = half.lines.find { it.include?("WORKTREE") }
    assert_includes header, "PR · CI"
    assert_includes header, "SV"
    assert_includes header, "LAST"
    refute_includes header, "NVIM"
    refute_includes header, "SERVICES"
    row = row_of(half, "tasks-filtering")
    assert_includes row, "#1421 ✗ 2"
    refute_includes row, "●●●◐○"
    assert_equal "◐", column(half, "SV", "tasks-filtering").strip[0], "worst service state is the summary"
    assert_equal "✗", column(half, "SV", "intake-forms").strip[0]
    assert_equal "○", column(half, "SV", "master").strip[0]

    _, compact = screen(width: 90)
    header = compact.lines.find { it.include?("WORKTREE") }
    refute_includes header, "LAST", "LAST goes once there is no room left"
    refute_includes header, "NVIM"
    assert_includes header, "PR · CI"
  end

  def test_live_session_feeds_last_column_and_agent_panel
    m = dashboard(width: 187)
    s = Wt::AgentSession.new(slug: "hipaa-logoff", agent: "codex-acp", connection: :connected, running: true,
                             tool_calls: [Wt::ToolCall.new(id: "t1", title: "bin/rails test:system", kind: "execute", status: :in_progress)])
    m = m.with(sessions: { "hipaa-logoff" => s }, ui: m.ui.with(selected: "hipaa-logoff"))
    text = render(m, width: 187, height: 70)
    row = row_of(text, "hipaa-logoff")
    assert_includes row, "● codex-acp"
    assert_includes row, "execute bin/rails test:system"
    assert_includes text, "codex-acp · ACP"
    assert_includes text, "Agent codex-acp"
    assert_includes text, "tool calls"
  end

  def test_head_is_middle_truncated_in_narrow_tiers_only
    _, half = screen(width: 140)
    cell = row_of(half, "intake-forms")
    assert_match(/ intake\/quest\S*…\S*-sections /, cell, "both ends of the branch survive")
    refute_includes cell, LONG_BRANCH

    _, two = screen(width: 187)
    assert_match(/ intake\/questionnaire-model-wi… /, row_of(two, "intake-forms"), "wide tiers cut the end")
  end

  def test_failed_source_shows_dimmed_question_mark_in_that_cell_only
    _, text = screen(width: 187)
    assert_equal "?", column(text, "STACK", "intake-forms").strip
    assert_equal "3/3", column(text, "STACK", "tasks-filtering").strip

    m = dashboard(width: 187)
    m = m.with(failures: m.failures.merge("pr:hipaa-logoff" => "x", "git:master" => "x", "nvim:tasks-filtering" => "x", "units" => "x"))
    text = render(m, width: 187, height: 70)
    assert_equal "?", column(text, "PR", "hipaa-logoff").strip
    assert_equal "?", column(text, "HEAD", "master").strip
    assert_equal "?", column(text, "NVIM", "tasks-filtering").strip
    assert_equal "?", column(text, "SERVICES", "hipaa-logoff").strip
    assert_includes text, "rails       ?", "pod table shows ? for unit state"
  end

  def test_filter_narrows_rows_and_shows_typed_text
    m = dashboard(width: 187)
    m, = step(m, "/", "h", "i", "p")
    text = render(m, width: 187, height: 70)
    assert_includes text, "/ hip▏"
    assert_includes text, "1 of 4"
    assert row_of(text, "hipaa-logoff")
    refute(text.lines.any? { it.include?(" intake-forms ") })

    _, placeholder = screen(width: 187)
    assert_includes placeholder, "/ filter by name, branch, PR…"
  end

  def test_branch_and_stack_panel
    _, text = screen(width: 187)
    assert_includes text, "⎇ tasks/filter-ui  ↑4 ↓0 · 4 uncommitted"
    assert_match(/#1421 Filter sidebar badges with bucket counts\s+ DRAFT /, text)
    assert_includes text, "✗ 2 failing rubocop, system  ✓ 12 passed"
    assert_includes text, "gh stack · 3 branches"
    assert_includes text, "⟳ needs restack"
    assert_match(/└─ #1412 tasks\/criteria-object\s+approved\s+✓/, text)
    assert_match(/   └─ #1418 tasks\/bucket-counts\s+review\s+⟳/, text)
    assert_match(/      └─ #1421 tasks\/filter-ui\s+draft\s+✗ 2\s+◀ HEAD/, text)
    assert_includes text, "[ ]  down/up"
  end

  def test_pod_panel
    _, text = screen(width: 187)
    assert_includes text, "◆ awaiting permission"
    assert_includes text, ":17014"
    assert_includes text, "● listening · 1 UI · 7 buffers"
    assert_match(/rails\s+● running\s+:13014\s+3\.8%\s+598M\s+1h40m/, text)
    assert_match(/postgres\s+● healthy\s+:55446\s+—\s+—\s+1h40m/, text)
    assert_match(/rustfs\s+◐ starting\s+:19014\s+—\s+—\s+8s/, text)
    assert_match(/playwright\s+○ stopped\s+—\s+—\s+—\s+—/, text)
  end

  def test_empty_workspace_renders_in_every_tier
    TIERS.each_value do |width|
      m = model(worktrees: [], width:, height: 70)
      assert_includes render(m, width:, height: 70), "no worktrees"
    end
  end

  def test_selection_scrolls_list_when_rows_exceed_panel
    wts = (1..40).map { worktree("wt-#{it}", id: it) }
    m = model(worktrees: wts, width: 187, height: 70)
    m = m.with(ui: m.ui.with(selected: "wt-40"))
    text = render(m, width: 187, height: 70)
    assert_match(/▌ wt-40/, text)
    refute_includes text, " wt-1 "
  end
end
