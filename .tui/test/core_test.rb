# frozen_string_literal: true

require "test_helper"

class TierTest < Minitest::Test
  def test_tier_boundaries
    assert_equal :compact, Wt::Tier.for(99)
    assert_equal :half, Wt::Tier.for(100)
    assert_equal :half, Wt::Tier.for(149)
    assert_equal :twothirds, Wt::Tier.for(150)
    assert_equal :twothirds, Wt::Tier.for(219)
    assert_equal :full, Wt::Tier.for(220)
  end
end

class UpdateCoreTest < Minitest::Test
  def test_resize_repicks_tier
    m, = step(model, RatatuiRuby::Event::Resize.new(width: 140, height: 70))
    assert_equal :half, m.ui.tier
  end

  def test_selection_clamps_at_ends
    m, = step(model, "down", "down", "down")
    assert_equal "tasks", m.ui.selected
    m, = step(m, "up", "up")
    assert_equal "master", m.ui.selected
  end

  def test_filter_narrows_visible_rows_and_esc_clears
    m, = step(model, "/", "t", "a", "s")
    assert_equal %w[tasks], m.visible_worktrees.map(&:slug)
    m, = step(m, "esc")
    assert_equal "", m.ui.filter
    refute m.ui.filter_editing
  end

  def test_keys_typed_into_filter_are_not_actions
    m, cmd = step(model, "/", "q")
    assert_equal "q", m.ui.filter
    assert_nil cmd
  end

  def test_tab_cycles_screens_and_theme_toggles
    m, = step(model, "tab")
    assert_equal :agents, m.ui.screen
    m, = step(m, "T")
    assert_equal :dark, m.ui.theme
  end

  def test_quit_exits
    _, cmd = step(model, "q")
    assert_kind_of Rooibos::Command::Exit, cmd
  end

  def test_confirm_blocks_other_keys_and_n_cancels
    m = model.with(ui: model.ui.with(confirm: Wt::Confirm.new(prompt: "Remove?", action: :quit)))
    m, cmd = step(m, "q")
    assert_nil m.ui.confirm
    assert_nil cmd, "q answered the dialog (as no) instead of quitting"
  end

  def test_failed_source_marks_key_and_success_clears_it
    m, = step(model, Wt::Msg::Fetched.new(key: "git:tasks", message: Wt::Msg::SourceFailed.new(key: "git:tasks", error: "boom")))
    assert m.failed?("git", "tasks")
    m, = step(m, Wt::Msg::Fetched.new(key: "git:tasks", message: Wt::Msg::GitStatusLoaded.new(slug: "tasks", status: Wt::GitStatus.new)))
    refute m.failed?("git", "tasks")
  end

  def test_inflight_fetch_is_not_rescheduled
    m, cmd = Wt::Refresh.on_tick(model, :fast)
    refute_nil cmd
    assert_includes m.inflight, "git:tasks"
    m2, = Wt::Refresh.on_tick(m, :fast)
    assert_equal m.inflight, m2.inflight
  end

  def test_agents_sort_by_urgency
    wts = %w[a b c d].each_with_index.map { |s, i| worktree(s, id: i) }
    agents = { "a" => Wt::AgentStatus.new(state: :waiting), "b" => Wt::AgentStatus.new(state: :working),
               "c" => Wt::AgentStatus.new(state: :permission), "d" => Wt::AgentStatus.new(state: :failed) }
    m = model(worktrees: wts).with(agents:)
    assert_equal %w[c d b a], m.agents_by_urgency
  end
end

class RootViewTest < Minitest::Test
  def test_renders_frame_with_hints
    screen = render(model(height: 20), width: 187, height: 20)
    assert_includes screen, "F1 Worktrees"
    assert_includes screen, "187×20 · ⅔"
    assert_includes screen, "quit"
  end

  def test_help_lists_every_binding_label
    m = model.with(ui: model.ui.with(help: true))
    screen = render(m, width: 187, height: 70)
    assert_includes screen, "remove worktree"
    assert_includes screen, "restack"
  end
end
