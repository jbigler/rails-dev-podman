# frozen_string_literal: true

require_relative "test_helper"

# One poller step at a time, against FakeShell and a fake clock; no thread is started.
class PollersTest < Minitest::Test
  R = Dashboard::Shell::Result
  BASE = "#{ROOT}/master"
  STACKED = "#{ROOT}/wt-stacked"

  def hub(raw = fixture_raw) = Dashboard::Hub.new(ws, raw:)

  def github_shell
    FakeShell.new(no_filters(BASE, STACKED).merge(
      "gh pr list --state open" => R.ok(fixture("gh-pr-list-open.json")),
      "gh pr list --state all" => R.ok(fixture("gh-pr-list.json")),
      "gh stack view" => R.ok(fixture("gh-stack-view.wt-stacked.json")),
      "git -C #{STACKED} rev-list" => R.ok("6\n")
    ))
  end

  def index_reads(shell) = shell.calls.count { it.argv.first == "gh" && it.argv.include?("all") }

  def test_failed_read_keeps_the_value_and_marks_the_source
    h = hub
    with_shell(FakeShell.new("podman ps" => R.fail("Error: cannot connect to podman"))) do
      Dashboard::LocalPoller.new(h, ws, Dashboard::Schedule.new(NOW)).refresh(:containers)
    end
    assert_equal "podman ps: Error: cannot connect to podman", h.snapshot.failed["containers"]
    assert_equal fixture_raw.containers, h.snapshot.raw.containers
  end

  def test_unit_env_reread_drops_a_vanished_file
    h = hub
    with_shell(FakeShell.new) { Dashboard::LocalPoller.new(h, ws, Dashboard::Schedule.new(NOW)).refresh(:unit_env) }
    assert_empty h.snapshot.raw.env # ROOT is not on this disk, so wt-stacked's file is gone
  end

  def test_on_demand_refresh_reads_the_index_and_the_viewed_stack_only
    h = hub(fixture_raw.with(prs: {}, pr_index: {}, commits: {}, stacks: {}))
    h.subscribe(viewing: "wt-stacked")
    shell = with_shell(github_shell) do |s|
      Dashboard::GithubPoller.new(h, ws, Dashboard::Schedule.new(NOW)).refresh(full: true)
      s
    end
    raw = h.snapshot.raw
    assert_equal fixture_raw.prs, raw.prs
    assert_equal fixture_raw.pr_index, raw.pr_index
    assert_equal fixture_raw.stacks, raw.stacks
    assert_equal({ "wt-stacked" => 6 }, raw.commits)
    assert_equal [STACKED], shell.calls.select { it.argv[0, 3] == %w[gh stack view] }.map(&:chdir)
  end

  def test_timer_refresh_skips_the_index_and_unviewed_stacks
    h = hub
    shell = with_shell(github_shell) do |s|
      Dashboard::GithubPoller.new(h, ws, Dashboard::Schedule.new(NOW)).refresh(full: false)
      s
    end
    assert_equal 0, index_reads(shell)
    assert(shell.calls.any? { it.argv.include?("open") })
    refute(shell.calls.any? { it.argv[0, 2] == %w[gh stack] })
  end

  def test_github_at_startup_on_hints_and_on_the_timer_only_with_a_page
    h = hub
    now = NOW
    poller = Dashboard::GithubPoller.new(h, ws, Dashboard::Schedule.new(now), clock: -> { now })
    shell = with_shell(github_shell) do |s|
      poller.tick # startup: on demand, no page needed
      now += 3600
      poller.tick # no page: never on the timer
      assert_equal 1, index_reads(s)
      assert_equal :run, poller.hint(:action)
      poller.tick
      assert_equal 2, index_reads(s)
      h.subscribe(viewing: "master")
      now += 299
      poller.tick # master has no open PR and no checks are pending: 300 s
      now += 1
      poller.tick
      s
    end
    assert_equal 2, index_reads(shell) # the timer never reads the index
    assert_equal 3, shell.calls.count { it.argv.include?("open") } # startup, the action, one timer tick
  end

  def test_hot_when_checks_pending_or_a_viewed_worktree_has_an_open_pr
    raw = fixture_raw
    refute Dashboard::GithubPoller.hot?(raw, Set[])
    refute Dashboard::GithubPoller.hot?(raw, Set["master"])
    assert Dashboard::GithubPoller.hot?(raw, Set["wt-01"])
    pr = raw.prs.values.first.with(checks: { pass: 1, fail: 0, pending: 2 })
    assert Dashboard::GithubPoller.hot?(raw.with(prs: raw.prs.merge("feature/x" => pr)), Set[])
  end
end
