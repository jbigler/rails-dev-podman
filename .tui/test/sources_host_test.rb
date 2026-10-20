# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

class SourcesHostTest < Minitest::Test
  include WtTestHelpers

  ROOT = "/home/jbigler/workspace/filial"

  def test_worktrees_parse_real_porcelain_base_first_with_registry_ids
    wts = Wt::Sources::Worktrees.parse(fixture("host", "worktree_list.porcelain"), fixture("host", "ports.registry"), root: ROOT)
    assert_equal 15, wts.size
    base = wts.first
    assert_equal ["master", true, "master", 0, "4b4dfe3"], [base.slug, base.base, base.branch, base.id, base.head]
    assert_equal [false], wts.drop(1).map(&:base).uniq
    idle = wts.find { it.slug == "bugfix-server-side-idle-lock" }
    assert_equal ["bugfix/server_side_idle_lock", 17, 17_017, "#{ROOT}/bugfix-server-side-idle-lock"],
                 [idle.branch, idle.id, idle.nvim_port, idle.path]
    # feature-skip-own-broadcast is in the registry under id 27; general_work keeps its underscore branch.
    assert_equal 27, wts.find { it.slug == "feature-skip-own-broadcast" }.id
    assert_equal "general_work", wts.find { it.slug == "general-work" }.branch
  end

  def test_worktrees_parse_detached_prunable_and_missing_registry_id
    wts = Wt::Sources::Worktrees.parse(fixture("host", "worktree_list_synthetic.porcelain"), "master:0\nbisect:4\n\n", root: "/ws")
    assert_equal %w[master bisect gone], wts.map(&:slug)
    bisect, gone = wts.drop(1)
    assert bisect.detached
    assert_nil bisect.branch
    assert_equal "1234567", bisect.head
    assert_equal 4, bisect.id
    assert gone.prunable
    refute gone.detached
    assert_nil gone.id
    assert_nil gone.app_port
  end

  def test_git_status_counts_clean_and_dirty
    clean = Wt::Sources::GitStatus.parse(fixture("host", "status_master.txt"))
    assert_equal Wt::GitStatus.new(branch: "master", upstream: "origin/master"), clean
    dirty = Wt::Sources::GitStatus.parse(fixture("host", "status_dirty.txt"))
    assert_equal 1, dirty.dirty
    assert_equal "origin/bugfix/server_side_idle_lock", dirty.upstream
  end

  def test_git_status_detached_ahead_behind_and_all_entry_kinds
    st = Wt::Sources::GitStatus.parse(fixture("host", "status_ahead_detached.txt"))
    assert st.detached
    assert_nil st.branch
    assert_nil st.upstream
    assert_equal 4, st.dirty
    ab = Wt::Sources::GitStatus.parse(fixture("host", "status_ahead_behind.txt"))
    assert_equal [3, 12, 0], [ab.ahead, ab.behind, ab.dirty]
  end

  def test_status_files_hook_and_bridge_formats_tolerating_bad_files
    cfg = config(root: fixture_root)
    statuses = Wt::Sources::StatusFiles.fetch(cfg).statuses
    assert_equal %w[bridge general-work master weird], statuses.keys.sort
    hook = statuses["master"]
    assert_equal :offline, hook.state
    assert_equal Time.utc(2026, 10, 16, 1, 58, 59), hook.updated_at
    assert_equal "claude", hook.agent, "the hook format only comes from Claude Code"
    bridge = statuses["bridge"]
    assert_equal [:permission, "claude", 2, 5, "Edit app/models/user.rb", Time.utc(2026, 10, 20, 9, 15)],
                 [bridge.state, bridge.agent, bridge.plan_done, bridge.plan_total, bridge.last, bridge.updated_at]
    weird = statuses["weird"]
    assert_equal [:offline, nil], [weird.state, weird.updated_at]
    assert Ractor.shareable?(statuses)
  end

  def test_status_files_missing_dir_is_empty
    assert_equal({}, Wt::Sources::StatusFiles.fetch(config(root: "/nonexistent/wt")).statuses)
  end

  def test_status_files_states
    %w[working waiting permission failed offline].each do |s|
      assert_equal s.to_sym, Wt::Sources::StatusFiles.parse(%({"state":"#{s}"})).state
    end
    assert_nil Wt::Sources::StatusFiles.parse("[1]")
  end

  def test_worktrees_fetch_failure_raises_so_source_fails
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "master"))
      assert_raises(Wt::Error) { Wt::Sources::Worktrees.fetch(config(root: dir)) }
    end
  end

  private

  # A root whose .container-config/status is the fixture status dir.
  def fixture_root
    @fixture_root ||= Dir.mktmpdir.tap do |dir|
      FileUtils.mkdir_p(File.join(dir, ".container-config"))
      File.symlink(fixture_path("host", "status"), File.join(dir, ".container-config", "status"))
    end
  end
end
