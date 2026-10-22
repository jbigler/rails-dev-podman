# frozen_string_literal: true

require_relative "test_helper"

class SourcesTest < Minitest::Test
  S = Dashboard::Sources
  R = Dashboard::Shell::Result

  def test_worktrees_keyed_by_folder_with_base_flagged
    refs = S::Worktrees.parse(fixture("git-worktree-list.txt"), base_path: "#{ROOT}/master")
    assert_equal 16, refs.size
    assert_equal ["master"], refs.select(&:base).map(&:name)
    stacked = refs.find { it.name == "wt-stacked" }
    assert_equal "feature/branch-72", stacked.branch
    assert_equal "#{ROOT}/wt-stacked", stacked.path
  end

  # git names the main worktree after the common dir (the GitSafety shadow).
  def test_worktrees_main_first_detached_and_prunable
    text = "worktree /run/x/gitcommon\nHEAD 123\nbranch refs/heads/master\n\n" \
           "worktree /r/a\nHEAD abc\ndetached\n\nworktree /r/gone\nHEAD def\nbranch refs/heads/x\nprunable gitdir file points to non-existent location\n"
    refs = S::Worktrees.parse(text, base_path: "/r/base")
    assert_equal %w[base a], refs.map(&:name)
    assert_equal ["/r/base", true, "master"], [refs.first.path, refs.first.base, refs.first.branch]
    refute refs.last.base
    assert_nil refs.last.branch
  end

  def test_git_status_ahead_behind_upstream_and_dirty
    master = S::GitStatus.parse(fixture("git-status.master.txt"))
    assert_equal [0, 0, "origin", 0], [master.ahead, master.behind, master.upstream, master.dirty_count]

    no_upstream = S::GitStatus.parse(fixture("git-status.wt-stacked.txt"))
    assert_nil no_upstream.ahead
    assert_nil no_upstream.upstream

    dirty = S::GitStatus.parse("# branch.ab +4 -1\n1 .M N... 100644 100644 100644 a b app.rb\n2 R. N... x y z w R100 n o\nu UU x\n? .local/\n")
    assert_equal [4, 1, 3], [dirty.ahead, dirty.behind, dirty.dirty_count]
  end

  def test_git_calls_carry_safety_env
    shell = FakeShell.new(
      "git -C /r/wt status" => R.ok(fixture("git-status.master.txt")),
      "gh pr list" => R.ok(fixture("gh-pr-list-open.json"))
    )
    with_shell(shell) do
      S::GitStatus.fetch(ws, "/r/wt")
      S::OpenPrs.fetch(ws)
    end
    status = shell.calls.find { it.argv[3] == "status" }
    gh = shell.calls.find { it.argv.first == "gh" }
    [status, gh].each do |call|
      assert_equal FakeGitSafety::SHADOW, call.env["GIT_COMMON_DIR"]
      assert_equal "4", call.env["GIT_CONFIG_COUNT"]
    end
    assert_includes status.argv, "--ignore-submodules=all"
    assert_equal "#{ROOT}/master", gh.chdir
  end

  def test_unsafe_git_config_fails_the_source_without_running_git
    shell = FakeShell.new("git -C /r/wt status" => R.ok(""))
    with_git_safety(FakeGitSafety.new(unsafe: true)) do
      with_shell(shell) { assert_raises(S::Failed) { S::GitStatus.fetch(ws, "/r/wt") } }
    end
    assert_empty shell.calls
  end

  def test_commit_count_against_the_pr_base
    shell = FakeShell.new("git -C /r/wt rev-list --count origin/feature/branch-65..HEAD" => R.ok("6\n"))
    with_shell(shell) { assert_equal 6, S::CommitCount.fetch(ws, "/r/wt", "feature/branch-65") }
    with_shell(FakeShell.new("git -C /r/wt rev-list" => R.fail("fatal: bad revision", status: 128))) do
      assert_nil S::CommitCount.fetch(ws, "/r/wt", "gone")
    end
    assert_nil S::CommitCount.fetch(ws, "/r/wt", nil)
  end

  def test_units_records
    units = S::Units.parse(fixture("systemctl.master.txt"))
    assert_equal "active", units.fetch("myproj-rails@master.service")["ActiveState"]
    assert_equal 6, units.size
  end

  def test_containers_health_and_epoch_start
    ctrs = S::Containers.parse(fixture("podman-ps.json"))
    db = ctrs.fetch("myproj-master-db")
    assert_equal ["running", "healthy"], [db.state, db.health]
    assert_equal Time.at(1_792_483_545), db.started_at
    assert_nil ctrs.fetch("myproj-master-rails").health
  end

  def test_unit_env_keys
    assert_equal({ "WORKTREE_HOST" => "wt-stacked.localhost", "APP_PORT" => "13022", "DB_PORT" => "55454", "NVIM_PORT" => "17022" },
                 S::UnitEnv.parse(fixture("unit-env.wt-stacked.env")))
    assert_equal({ "S3_HOST" => "a=b" }, S::UnitEnv.parse("POSTGRES_PASSWORD=x\nS3_HOST=a=b\nnot a pair\n"))
  end

  def test_unit_env_reread_only_on_mtime_change
    Dir.mktmpdir do |root|
      w = Dashboard::Workspace.new(root:, prefix: "p", base_name: "master")
      FileUtils.mkdir_p(File.dirname(w.unit_env_file("a")))
      File.write(w.unit_env_file("a"), fixture("unit-env.wt-stacked.env"))
      mtime, env = S::UnitEnv.fetch(w, %w[a b], {})[:changed].fetch("a")
      assert_equal "13022", env["APP_PORT"]
      assert_equal({ changed: {}, gone: [] }, S::UnitEnv.fetch(w, %w[a b], { "a" => mtime }))
      File.delete(w.unit_env_file("a"))
      assert_equal ["a"], S::UnitEnv.fetch(w, %w[a b], { "a" => mtime })[:gone]
    end
  end

  def test_tasks_and_their_arguments
    tasks = S::Tasks.parse(fixture("mise-tasks.json"))
    by_name = tasks.to_h { [it.name, it] }
    assert_equal :required, S::Tasks.args(by_name.fetch("wt").usage)
    assert_equal :optional, S::Tasks.args(by_name.fetch("test:rails").usage)
    assert_nil S::Tasks.args(by_name.fetch("up").usage)
  end

  def test_pr_index_prefers_open
    json = JSON.generate([
      { number: 5, headRefName: "b", state: "MERGED", title: "old", url: "https://x/5" },
      { number: 3, headRefName: "b", state: "OPEN", title: "new", url: "https://x/3" }
    ])
    pr = S::PrIndex.parse(json).fetch("b")
    assert_equal [3, :open, :none, "https://x/3"], [pr.number, pr.state, pr.review, pr.url]
  end

  def test_pr_index_merged_without_checks
    pr = S::PrIndex.parse(fixture("gh-pr-list.json")).values.find { it.state == :merged }
    refute_nil pr
    assert_nil pr.checks
  end

  def test_open_prs_carry_checks
    pr = S::OpenPrs.parse(fixture("gh-pr-list-open.json"))["feature/branch-72"]
    assert_equal({ pass: 17, fail: 0, pending: 0 }, pr.checks)
    assert_equal [10_329, :approved, "feature/branch-65"], [pr.number, pr.review, pr.base_ref]
    assert_equal "https://github.com/example-org/app/pull/10329", pr.url
  end

  def test_open_prs_failure_raises
    shell = FakeShell.new("gh pr list" => R.fail("HTTP 401: Bad credentials"))
    with_shell(shell) { assert_raises(S::Failed) { S::OpenPrs.fetch(ws) } }
  end

  def test_stack
    stack = S::Stack.parse(fixture("gh-stack-view.wt-stacked.json"))
    assert_equal 21, stack.branches.size
    assert_equal 5, stack.merged.size
    assert_equal 16, stack.open.size
    assert_equal 7, stack.position
    assert stack.restack_needed?
  end

  def test_stack_nonzero_exit_is_no_stack_but_missing_gh_is_a_failure
    with_shell(FakeShell.new("gh stack view" => R.fail(fixture("gh-stack-view.master.json")))) do
      assert_nil S::Stack.fetch(ws, "/r/master")
    end
    with_shell(FakeShell.new) { assert_raises(S::Failed) { S::Stack.fetch(ws, "/r/master") } }
  end

  def test_repo_from_remote_url
    assert_equal "example-org/app", S::Repo.parse("git@github.com:example-org/app.git\n")
    assert_equal "example-org/app", S::Repo.parse("https://github.com/example-org/app")
  end

  def test_agent_files_reread_only_on_mtime_change
    Dir.mktmpdir do |root|
      w = Dashboard::Workspace.new(root:, prefix: "p", base_name: "master")
      FileUtils.mkdir_p(w.status_dir)
      File.write(w.status_file("a"), fixture("status", "wt-01.json"))
      first = S::AgentFiles.fetch(w, %w[a b], {})
      mtime, file = first[:changed].fetch("a")
      assert_equal "offline", file.state
      assert_equal({ changed: {}, gone: [] }, S::AgentFiles.fetch(w, %w[a b], { "a" => mtime }))
      File.delete(w.status_file("a"))
      assert_equal ["a"], S::AgentFiles.fetch(w, %w[a b], { "a" => mtime })[:gone]
    end
  end

  def test_status_file_keeps_rtk_savings
    file = S::AgentFiles.parse(fixture("status", "wt-stacked.json"))
    assert_equal 377_115, file.rtk["total_saved"]
    assert_nil S::AgentFiles.parse('{"v":2,"phase":"done","rtk":"junk"}').rtk
  end

  def test_stale_units_names_each_unit
    stderr = "These installed units no longer match .container-config/quadlet/:\n\n" \
             "  myproj-rails@.container                  differs from the template\n" \
             "  myproj-firewall.json                     not installed\n\n" \
             "systemd is still running the old generated units. Re-render them:\n  mise run units:install\n"
    shell = FakeShell.new("#{ROOT}/.scripts/quadlet.sh check-stale" => R.fail(stderr))
    with_shell(shell) do
      assert_equal ["myproj-rails@.container differs from the template", "myproj-firewall.json not installed"], S::StaleUnits.fetch(ws)
    end
    assert_equal({ "PROJECT_PREFIX" => "myproj" }, shell.calls.first.env)
    with_shell(FakeShell.new("#{ROOT}/.scripts/quadlet.sh check-stale" => R.ok("installed units match the templates\n"))) do
      assert_equal [], S::StaleUnits.fetch(ws)
    end
    with_shell(FakeShell.new("#{ROOT}/.scripts/quadlet.sh check-stale" => R.fail("error: podman info failed\n"))) do
      assert_raises(S::Failed) { S::StaleUnits.fetch(ws) }
    end
  end

  def test_autostart_from_is_enabled
    argv = "systemctl --user is-enabled myproj-dashboard.service"
    with_shell(FakeShell.new(argv => R.ok("enabled\n"))) { assert_equal :enabled, S::Autostart.fetch(ws) }
    with_shell(FakeShell.new(argv => R.new(stdout: "disabled\n", stderr: "", status: 1, timed_out: false))) do
      assert_equal :disabled, S::Autostart.fetch(ws)
    end
    with_shell(FakeShell.new(argv => R.new(stdout: "not-found\n", stderr: "", status: 1, timed_out: false))) do
      assert_equal :unknown, S::Autostart.fetch(ws)
    end
    with_shell(FakeShell.new) { assert_equal :unknown, S::Autostart.fetch(ws) }
  end

  def test_workspace_discover_walks_up_to_the_base
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "master", ".git"))
      FileUtils.mkdir_p(File.join(root, ".dashboard"))
      w = Dashboard::Workspace.discover(env: { "PROJECT_PREFIX" => "p", "WT_DASHBOARD_PORT" => "7700" }, cwd: File.join(root, ".dashboard"))
      assert_equal [root, "p", "master", "7700"], [w.root, w.prefix, w.base_name, w.port]
      assert_equal "#{root}/.unit-env/wt-1.env", w.unit_env_file("wt-1")
      assert_equal "p-dashboard.service", w.dashboard_unit
      assert_nil Dashboard::Workspace.discover(env: {}, cwd: root).port
    end
  end

  def test_error_line_skips_mise_boilerplate
    stderr = "[up] $ podman-wt.sh up\nerror: unit files out of date; run mise run units:install\n[up] ERROR task failed\n"
    assert_equal "error: unit files out of date; run mise run units:install", R.fail(stderr).error_line
    stderr = "mise ERROR no tasks defined in /w. Are you in a project directory?\nmise ERROR Version: 2026.10.15\n" \
             "mise ERROR Run with --verbose or MISE_VERBOSE=1 for more information\n"
    assert_equal "no tasks defined in /w. Are you in a project directory?", R.fail(stderr).error_line
  end
end
