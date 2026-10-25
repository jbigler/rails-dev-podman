# frozen_string_literal: true

require_relative "test_helper"

# One poller step at a time, against FakeShell and a fake clock; no thread is started.
class PollersTest < Minitest::Test
  R = Dashboard::Shell::Result
  BASE = "#{ROOT}/master"
  STACKED = "#{ROOT}/wt-stacked"

  def hub(raw = fixture_raw) = Dashboard::Hub.new(ws, raw:)

  def github_shell(overrides = {})
    FakeShell.new({
      "gh pr list --state open" => R.ok(fixture("gh-pr-list-open.json")),
      "gh pr list --state all" => R.ok(fixture("gh-pr-list.json")),
      "gh stack view" => R.ok(fixture("gh-stack-view.wt-stacked.json")),
      "git -C #{STACKED} rev-list" => R.ok("6\n")
    }.merge(overrides))
  end

  def index_reads(shell) = shell.calls.count { it.argv.first == "gh" && it.argv.include?("all") }
  def open_reads(shell) = shell.calls.count { it.argv.first == "gh" && it.argv.include?("open") }
  def stack_reads(shell) = shell.calls.select { it.argv[0, 3] == %w[gh stack view] }.map(&:chdir)

  def local_poller(h = hub) = Dashboard::LocalPoller.new(h, ws, Dashboard::Schedule.new(NOW))

  def test_pokes_are_taken_together
    poller = local_poller
    2.times { poller.poke }
    assert poller.poked?(0)
    refute poller.poked?(0)
  end

  def test_a_poke_racing_the_timeout_is_not_lost
    poller = local_poller
    wake = poller.instance_variable_get(:@wake)
    raced = false
    # The poke lands just after the timed wait gave up, before the step returns.
    wake.define_singleton_method(:pop) do |*args, **opts|
      super(*args, **opts).tap do
        poller.poke unless raced
        raced = true
      end
    end
    assert poller.poked?(0)
    refute poller.poked?(0)
  end

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

  # Ruling 10: a worktree viewed after a refresh gets its stack and commit
  # count on the next tick, not the next timer tick; the timer is not reset.
  def test_newly_viewed_worktree_is_read_on_the_next_tick
    h = hub(fixture_raw.with(stacks: {}, commits: {}))
    now = NOW
    poller = Dashboard::GithubPoller.new(h, ws, Dashboard::Schedule.new(now), clock: -> { now })
    shell = with_shell(github_shell) do |s|
      poller.tick # startup refresh at t0, nothing viewed
      now += 5
      h.subscribe(viewing: "wt-stacked")
      assert_equal :drop, poller.hint(:focus) # the connect hint is coalesced away
      poller.tick
      assert_equal [STACKED], stack_reads(s)
      assert_equal [fixture_raw.stacks, { "wt-stacked" => 6 }], [h.snapshot.raw.stacks, h.snapshot.raw.commits]
      poller.tick
      assert_equal [STACKED], stack_reads(s) # read once
      assert_equal 1, open_reads(s)
      now = NOW + 60
      poller.tick # hot (wt-stacked has an open PR): due 60 s after the t0 refresh
      s
    end
    assert_equal 2, open_reads(shell)
  end

  def test_a_viewed_worktree_already_read_waits_for_the_timer
    h = hub(fixture_raw.with(stacks: { "wt-stacked" => nil })) # read: not in a stack
    now = NOW
    poller = Dashboard::GithubPoller.new(h, ws, Dashboard::Schedule.new(now), clock: -> { now })
    shell = github_shell("gh stack view" => R.fail("gh: not found", status: 127))
    with_shell(shell) do
      poller.tick
      now += 5
      h.subscribe(viewing: "wt-stacked")
      h.subscribe(viewing: "wt-01")
      poller.tick
      poller.tick
    end
    assert_equal ["#{ROOT}/wt-01"], stack_reads(shell) # wt-01 once: its failed read is not retried every tick
    assert_equal Dashboard::UNKNOWN, h.snapshot.worktrees.find { it.name == "wt-01" }.stack
  end
end
