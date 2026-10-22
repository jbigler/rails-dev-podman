# frozen_string_literal: true

require_relative "test_helper"

# Source results in, change events out to each subscriber's queue.
class HubTest < Minitest::Test
  def hub(raw = fixture_raw) = Dashboard::Hub.new(ws, raw:)

  # Everything queued so far; apply is synchronous, so nothing is in flight.
  def drain(sub) = Array.new(sub.queue.size) { sub.queue.pop }

  def status_file(phase) = Dashboard::StatusFile.new(v: 2, state: "working", phase:, ts: NOW, message: "Which database?", tool: nil, last_message: nil, rtk: nil)

  def test_detail_events_only_to_viewers
    h = hub
    first = h.subscribe(viewing: "wt-01")
    second = h.subscribe(viewing: "wt-stacked")
    h.apply([:git, "wt-stacked"], Dashboard::GitInfo.new(ahead: 2, behind: 0, upstream: "origin", dirty_count: 3))
    assert_equal [[:row, "wt-stacked"]], drain(first)
    assert_equal [[:row, "wt-stacked"], [:detail, "wt-stacked"]], drain(second)
    assert_equal 3, h.snapshot.worktrees.find { it.name == "wt-stacked" }.dirty_count
  end

  def test_notify_on_question
    claude = Dashboard::Container.new(name: "myproj-wt-01-claude", state: "running", health: nil, exit_code: 0, started_at: NOW - 3600)
    raw = fixture_raw.with(containers: fixture_raw.containers.merge(claude.name => claude),
                           agent_files: { "wt-01" => [NOW - 60, status_file("working")] })
    h = hub(raw)
    sub = h.subscribe(viewing: "wt-stacked")
    asked = { changed: { "wt-01" => [NOW, status_file("question")] }, gone: [] }
    h.apply(:agent_files, asked)
    events = drain(sub)
    assert_equal 1, events.count([:notify, "wt-01"])
    assert_includes events, [:header] # one more worktree needs input
    assert_equal 1, h.snapshot.needs_input_count
    h.apply(:agent_files, asked)
    assert_empty drain(sub)
  end

  def test_gone_when_viewed_worktree_removed
    h = hub
    viewer = h.subscribe(viewing: "wt-01")
    other = h.subscribe(viewing: "wt-stacked")
    h.apply(:worktrees, fixture_raw.refs.reject { it.name == "wt-01" })
    assert_equal [[:row, "wt-01"], [:gone, "wt-01"]], drain(viewer)
    assert_equal [[:row, "wt-01"]], drain(other)
  end

  def test_failed_source_keeps_its_value_until_it_reads_again
    h = hub
    sub = h.subscribe(viewing: nil)
    h.apply(:units, nil, failed: "systemctl: no user session")
    state = h.snapshot
    assert_equal "systemctl: no user session", state.failed["units"]
    assert_equal fixture_raw.units, state.raw.units
    assert_equal Dashboard::UNKNOWN, state.worktrees.first.services
    assert_equal 16, drain(sub).count { it.first == :row }
    h.apply(:units, fixture_raw.units)
    refute h.snapshot.failed.key?("units")
    refute_equal Dashboard::UNKNOWN, h.snapshot.worktrees.first.services
  end

  def wt(h, name) = h.snapshot.worktrees.find { it.name == name }

  def test_per_worktree_failure_is_marked_per_worktree
    h = hub
    h.apply([:stacks, "wt-stacked"], nil, failed: "gh stack view: timed out")
    assert_equal Dashboard::UNKNOWN, wt(h, "wt-stacked").stack
    assert_equal "gh stack view: timed out", h.snapshot.failed["stacks:wt-stacked"]
  end

  def test_git_failure_marks_that_worktrees_git_cells_unknown
    h = hub
    h.apply([:git, "wt-stacked"], nil, failed: "git status: timed out")
    stacked = wt(h, "wt-stacked")
    assert_equal [Dashboard::UNKNOWN] * 4, [stacked.ahead, stacked.behind, stacked.upstream, stacked.dirty_count]
    master = wt(h, "master")
    assert_equal [0, 0, "origin", 0], [master.ahead, master.behind, master.upstream, master.dirty_count]
    h.apply([:git, "wt-stacked"], Dashboard::GitInfo.new(ahead: 1, behind: 0, upstream: "origin", dirty_count: 0))
    assert_equal 1, wt(h, "wt-stacked").ahead
  end

  def test_commit_count_failure_marks_the_pr_commits_unknown
    h = hub
    h.apply([:commits, "wt-stacked"], nil, failed: "git rev-list: timed out")
    pr = wt(h, "wt-stacked").pr
    assert_equal [10_329, Dashboard::UNKNOWN], [pr.number, pr.commits]
  end

  def test_reread_results_merge_and_drop_gone_files
    h = hub
    env = { "APP_PORT" => "13001" }
    h.apply(:unit_env, { changed: { "wt-01" => [NOW, env] }, gone: ["wt-stacked"] })
    assert_equal({ "wt-01" => [NOW, env] }, h.snapshot.raw.env)
    assert_equal "13001", h.snapshot.worktrees.find { it.name == "wt-01" }.services.first.port
  end

  def test_removed_worktrees_leave_the_per_worktree_values_and_failures
    h = hub
    h.apply([:stacks, "wt-stacked"], nil, failed: "gh stack view: timed out")
    h.apply([:git, "wt-01"], nil, failed: "git status: timed out")
    h.apply(:units, nil, failed: "systemctl: no user session")
    h.apply(:worktrees, fixture_raw.refs.reject { it.name == "wt-stacked" })
    raw = h.snapshot.raw
    assert_equal [{}, {}, {}, {}], [raw.env, raw.commits, raw.stacks, raw.git.slice("wt-stacked")]
    assert_equal %w[git:wt-01 units], h.snapshot.failed.keys.sort
  end

  def test_header_when_stale_units_or_autostart_change
    h = hub
    sub = h.subscribe(viewing: "wt-01")
    h.apply(:stale_units, ["myproj-rails@.container template changed"])
    h.apply(:autostart, :enabled)
    h.apply(:autostart, :enabled)
    assert_equal [[:header], [:header]], drain(sub)
  end

  def test_subscriptions_and_viewed_names
    h = hub
    a = h.subscribe(viewing: "wt-01")
    b = h.subscribe(viewing: nil)
    assert_equal [2, Set["wt-01"]], [h.subscriber_count, h.viewed_names]
    h.view(b, "wt-stacked")
    assert_equal "wt-stacked", b.viewing
    assert_equal Set["wt-01", "wt-stacked"], h.viewed_names
    h.unsubscribe(a)
    assert_equal [1, Set["wt-stacked"]], [h.subscriber_count, h.viewed_names]
    assert_equal [], h.snapshot.jobs
  end

  def job(id, state) = Dashboard::Job.new(id:, worktree: "wt-01", label: "up", state:, exit_status: nil, started_at: NOW, finished_at: nil, lines: [], created: nil)

  # A running job outlasts finished ones; an update keeps the job in its place.
  def test_publish_job_keeps_the_last_twenty_and_tells_every_page
    h = hub
    a = h.subscribe(viewing: "wt-01")
    b = h.subscribe(viewing: nil)
    h.publish_job(job(1, :running))
    (2..26).each { h.publish_job(job(it, :ok)) }
    h.publish_job(job(1, :failed))
    jobs = h.snapshot.jobs
    assert_equal [1, *8..26], jobs.map(&:id)
    assert_equal :failed, jobs.first.state
    expected = [[:job, 1], *(2..26).map { [:job, it] }, [:job, 1]]
    assert_equal [expected, expected], [drain(a), drain(b)]
  end

  def test_unknown_source_is_an_error
    assert_raises(ArgumentError) { hub.apply(:weather, 1) }
  end
end
