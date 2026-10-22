# frozen_string_literal: true

require_relative "test_helper"

# The refresh schedule on a fake clock: plain Time values, no threads.
class ScheduleTest < Minitest::Test
  T0 = NOW

  def schedule = Dashboard::Schedule.new(T0)

  def test_local_sources_on_their_intervals
    s = schedule
    assert_equal %i[worktrees git units containers agent_files unit_env stale_units autostart], s.local_due(T0)
    assert_empty s.local_due(T0 + 0.5)
    assert_equal %i[agent_files unit_env], s.local_due(T0 + 1)
    assert_equal %i[git units containers agent_files unit_env], s.local_due(T0 + 3)
    assert_equal %i[worktrees agent_files unit_env], s.local_due(T0 + 5)
    assert_includes s.local_due(T0 + 60), :stale_units
  end

  def test_poke_makes_every_local_source_due_and_restarts_the_intervals
    s = schedule
    s.local_due(T0)
    assert_equal %i[worktrees git units containers agent_files unit_env stale_units autostart], s.local_all(T0 + 2)
    assert_equal %i[agent_files unit_env], s.local_due(T0 + 3)
    assert_includes s.local_due(T0 + 62), :autostart
  end

  def test_no_github_without_pages
    assert_equal false, schedule.github_due?(T0 + 3600, subscribers: 0, hot: true)
  end

  def test_hot_interval_60
    s = schedule
    s.github_started(T0)
    assert_equal false, s.github_finished(T0)
    refute s.github_due?(T0 + 59, subscribers: 1, hot: true)
    assert s.github_due?(T0 + 60, subscribers: 1, hot: true)
    refute s.github_due?(T0 + 299, subscribers: 1, hot: false)
    assert s.github_due?(T0 + 300, subscribers: 1, hot: false)
  end

  def test_not_due_while_running
    s = schedule
    s.github_started(T0)
    refute s.github_due?(T0 + 3600, subscribers: 1, hot: true)
  end

  def test_focus_hints_coalesce
    s = schedule
    assert_equal :run, s.hint(T0, :focus)
    s.github_finished(T0)
    assert_equal :drop, s.hint(T0 + 5, :focus)
    assert_equal :run, s.hint(T0 + 11, :focus)
    assert_equal :drop, s.hint(T0 + 12, :focus) # that refresh is still running
  end

  def test_action_hint_queues
    s = schedule
    s.github_started(T0)
    assert_equal :queued, s.hint(T0 + 1, :action)
    assert_equal true, s.github_finished(T0 + 2)
    assert_equal :drop, s.hint(T0 + 3, :focus) # the rerun counts as running
    assert_equal false, s.github_finished(T0 + 4)
  end

  def test_action_hint_runs_even_right_after_a_refresh
    s = schedule
    s.github_started(T0)
    s.github_finished(T0)
    assert_equal :run, s.hint(T0 + 1, :action)
  end
end
