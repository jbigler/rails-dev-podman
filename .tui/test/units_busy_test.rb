# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Stale Quadlet units (`up` refuses them) and the "something is running" marks.
class StaleUnitsTest < Minitest::Test
  def result(status, stderr = "") = Wt::Shell::Result.new(stdout: "", stderr:, status:, timed_out: false)

  def test_check_stale_rows_become_unit_names
    assert_equal %w[filial-agent@.container filial-rails@.container],
                 Wt::Sources::UnitFiles.parse(1, fixture("pod", "check_stale.stderr"))
    assert_equal [], Wt::Sources::UnitFiles.parse(0, "installed units match the templates\n")
  end

  def test_a_check_that_cannot_run_is_a_source_failure_not_all_clear
    Wt::Shell.stub(:capture, result(2, "error: PROJECT_PREFIX unset\n")) do
      assert_raises(Wt::Error) { Wt::Sources::UnitFiles.fetch(config) }
    end
  end

  def test_up_failure_toast_names_the_cause_not_mises_trailer
    finished = Wt::Msg::CommandFinished.new(label: "up", slug: "master", status: 1, stderr: fixture("pod", "up_stale.stderr"), refresh: false)
    assert_equal "error: the installed units are out of date; see above", finished.stderr_line
    assert_equal "boom", Wt::Shell.error_line("[up] $ x\nboom\n[up] ERROR task failed\n")
  end

  def test_s_with_stale_units_offers_install_then_up
    m = model.with(stale_units: %w[filial-rails@.container])
    m, cmd = step(m, "s")
    assert_nil cmd, "does not run an up that is bound to fail"
    assert_includes m.ui.confirm.prompt, "filial-rails@.container"
    _, cmd = step(m, "y")
    assert_kind_of Wt::Commands::MiseChain, cmd
    assert_equal [["units:install"], ["up"]], cmd.tasks.map(&:args)
    assert_equal ["/ws", "/ws/master"], cmd.tasks.map(&:cwd)
  end

  def test_s_with_current_units_just_runs_up
    _, cmd = step(model.with(stale_units: []), "s")
    assert_equal ["up"], cmd.args
  end

  def test_chain_stops_at_the_first_failure_and_reports_it_for_the_worktree
    chain = Wt::Commands::MiseChain.new(tasks: [Wt::Commands.mise(model, "units:install", nil, "units:install"),
                                                Wt::Commands.mise(model, "up", "master", "up")])
    calls = []
    out = Queue.new
    outlet = Object.new.tap { |o| o.define_singleton_method(:put) { |m| out << m } }
    Wt::Shell.stub(:capture, ->(argv, **) { calls << argv; result(1, "error: podman info failed\n") }) do
      chain.call(outlet, Struct.new(:canceled?).new(false))
    end
    assert_equal [%w[mise run units:install]], calls
    msg = out.pop
    assert_equal ["units:install", "master", 1], [msg.label, msg.slug, msg.status]
  end

  def test_top_bar_says_units_are_out_of_date
    screen = render(model(width: 187, height: 20).with(stale_units: %w[a b]), width: 187, height: 20)
    assert_includes screen, "2 units out of date · U install"
  end
end

class BusyTest < Minitest::Test
  def test_up_marks_the_worktree_busy_until_it_finishes
    m, = step(model.with(stale_units: []), "s")
    assert_equal "up", m.busy["master"].label
    screen = render(m.with(ui: m.ui.with(width: 187, height: 40)), width: 187, height: 40)
    assert_includes screen, "⟳ up master"
    assert_includes screen, "Pod filial-master · ⟳ up"

    m, = step(m, Wt::Msg::CommandFinished.new(label: "up", slug: "master", status: 0, stderr: "", refresh: false))
    assert_empty m.busy
  end

  def test_a_failed_chain_still_clears_the_worktree
    m = model.with(stale_units: %w[x])
    m, = step(m, "s", "y")
    assert_equal "units:install → up", m.busy["master"].label
    m, = step(m, Wt::Msg::CommandFinished.new(label: "units:install", slug: "master", status: 1, stderr: "error: x", refresh: false))
    assert_empty m.busy
  end

  def test_workspace_actions_show_in_the_top_bar
    m, = step(model, "U")
    screen = render(m.with(ui: m.ui.with(width: 187, height: 20)), width: 187, height: 20)
    assert_includes screen, "⟳ units:install workspace"
  end

  def test_narrow_tiers_show_the_busy_mark_in_the_summary_column
    m, = step(model.with(stale_units: []), "s")
    screen = render(m.with(ui: m.ui.with(width: 140, height: 40)), width: 140, height: 40)
    assert_match(/master .*⟳/, screen)
  end
end
