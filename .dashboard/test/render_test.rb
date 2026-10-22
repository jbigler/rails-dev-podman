# frozen_string_literal: true

require "test_helper"

class RenderTest < Minitest::Test
  R = Dashboard::Render
  U = Dashboard::UNKNOWN

  def state = @state ||= Dashboard::Hub.new(ws, raw: fixture_raw).snapshot
  def wt(name, st = state) = st.worktrees.find { it.name == name }

  # The state with one worktree replaced by `yield`'s result.
  def changed(name)
    state.with(worktrees: state.worktrees.map { it.name == name ? yield(it) : it })
  end

  def test_dom_id
    assert_equal "row-wt-01", R.dom_id("row", "wt-01")
    assert_equal "row-app_2ev2_3cx_3e", R.dom_id("row", "app.v2<x>")
    assert_equal "job-a_20b", R.dom_id("job", "a b")
  end

  def test_row_marks_selection_and_links
    html = R.row(wt("wt-stacked"), selected: true)
    assert_includes html, 'id="row-wt-stacked"'
    assert_includes html, 'href="/w/wt-stacked"'
    assert_includes html, 'aria-current="page"'
    assert_includes html, "7/21"
    assert_includes html, "#10329"
    refute_includes R.row(wt("wt-01"), selected: false), "aria-current"
  end

  def test_unknown_cells_render_question_marks
    unknown = wt("wt-stacked").with(ahead: U, behind: U, dirty_count: U, services: U, stack: U, pr: U, agent: U)
    row = R.row(unknown, selected: false)
    %w[c-stack c-pr c-svc c-agent].each { assert_match(/class="#{it}[^"]*">\?</, row) }
    detail = R.detail(unknown, state)
    assert_includes detail, "↑? ↓?"
    assert_includes detail, "? uncommitted"
    assert_includes detail, "stack ?"
    assert_includes detail, "PR ?"
    services = detail[%r{<section class="block services">.*?</section>}m]
    assert_match(%r{<h3>services</h3>\s*<p class="muted">\?</p>}, services)
    refute_includes services, "<table"
  end

  def test_stacked_head_with_unknown_pr
    st = changed("wt-stacked") { it.with(pr: U) }
    html = R.detail(wt("wt-stacked", st), st)
    head = html[%r{<li class="stack-branch head">.*?</li>}m]
    assert_includes head, '<span class="muted">PR ?</span>'
    refute_includes html, "no PR"
  end

  def test_unknown_pr_commits
    w = wt("wt-stacked")
    st = changed("wt-stacked") { it.with(stack: nil, pr: it.pr.with(commits: U)) }
    assert_includes R.detail(wt("wt-stacked", st), st), "? commits"
    assert_includes R.detail(w, state), "6 commits"
  end

  def test_stack_top_down_with_head_and_merged
    html = R.detail(wt("wt-stacked"), state)
    assert_includes html, "◀ HEAD"
    assert_includes html, "✓ 5 merged"
    stack = html[html.index('<ol class="stack">')..]
    assert_operator stack.index("feature/branch-73"), :<, stack.index("feature/branch-72")
    assert_operator stack.index("feature/branch-72"), :<, stack.index("feature/branch-65")
    assert_includes html, 'href="https://github.com/example-org/app/pull/10329"'
    assert_match(/<details[^>]*>\s*<summary[^>]*>.*✓ 5 merged/m, html)
    assert_includes html, "restack needed"
  end

  def test_services_and_logs_links
    html = R.detail(wt("wt-stacked"), state)
    assert_includes html, ":13022"
    assert_includes html, 'href="http://logs.localhost/show?name=myproj-wt-stacked-rails"'
  end

  def test_app_links_follow_rails
    up = R.detail(wt("wt-stacked"), state)
    assert_includes up, 'href="http://wt-stacked.localhost/letter_opener"'
    assert_includes up, 'href="http://vnc.wt-stacked.localhost/vnc.html?path=websockify&amp;autoconnect=1&amp;reconnect=1&amp;reconnect_delay=2000&amp;resize=scale"'
    assert_includes up, 'href="http://s3-ui.wt-stacked.localhost"'
    down = R.detail(wt("wt-02"), state)
    assert_includes down, "wt-02.localhost"
    refute_includes down, 'href="http://wt-02.localhost'
    assert_includes down, 'aria-disabled="true"'
  end

  def test_agent_tail_and_rtk
    rtk = { "total_commands" => 548, "total_input" => 143_022, "total_output" => 97_714, "total_saved" => 45_561, "avg_savings_pct" => 31.86 }
    file = Dashboard::StatusFile.new(v: 2, state: nil, phase: "done", ts: NOW, message: nil, tool: nil, last_message: "first " * 200 + "the end", rtk:)
    st = changed("wt-01") { it.with(agent: Dashboard::Agent.of(:done, since: NOW, last_message: file.last_message)) }
    st = st.with(raw: st.raw.with(agent_files: { "wt-01" => [NOW, file] }))
    html = R.detail(wt("wt-01", st), st)
    assert_includes html, "the end"
    assert_includes html, "…"
    assert_includes html, "rtk 45.6K saved · 32%"
  end

  def test_header_counts_need_input_and_stale_units
    plain = R.header(state, repo: "example-org/app")
    assert_includes plain, '<span class="repo">example-org/app</span>'
    refute_includes plain, "need input"
    assert_includes plain, 'href="http://logs.localhost"'
    assert_includes plain, 'href="http://127.0.0.1:8080/"'
    st = changed("wt-01") { it.with(agent: Dashboard::Agent.of(:permission, since: NOW)) }
    st = st.with(raw: st.raw.with(stale_units: ["myproj-rails@.container\tdiffers"]))
    html = R.header(st, repo: "example-org/app")
    assert_includes html, "◆ 1 need input"
    assert_includes html, "myproj-rails@.container"
    assert_includes R.layout(st, token: "t", repo: "example-org/app") { "" }, "<title>◆ 1 · wt · example-org/app</title>"
  end

  def test_page_without_worktrees
    st = Dashboard::Hub.new(ws).snapshot
    html = R.page(st, nil, repo: "myproj")
    assert_includes html, 'id="header"'
    assert_includes html, 'id="detail"'
    assert_includes html, 'id="actions"'
  end
end
