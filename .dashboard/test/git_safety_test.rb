# frozen_string_literal: true

require "test_helper"

# Real git against temp repos: a base worktree with an origin, and a linked
# worktree `wt` one commit ahead of its upstream. Every .txt goes through the
# `evil` filter, which no repo config defines until a test writes it.
class GitSafetyTest < Minitest::Test
  S = Dashboard::Sources
  EVIL_KEYS = /\A(filter\.|include|core\.fsmonitor|core\.hookspath|extensions\.worktreeconfig|alias\.|core\.sshcommand)/i

  def setup
    @root = Dir.mktmpdir("git-safety")
    @run = Dir.mktmpdir("git-safety-run")
    @base = "#{@root}/master"
    @wt = "#{@root}/wt"
    Dir.mkdir(@base)
    git "init", "--quiet", "--initial-branch=master"
    File.write("#{@base}/.gitattributes", "*.txt filter=evil\n")
    File.write("#{@base}/a.txt", "hi\n")
    File.write("#{@base}/b.md", "one\n")
    git "add", "."
    git "commit", "--quiet", "--no-verify", "-m", "init"
    git_in @root, "clone", "--quiet", "--bare", @base, "#{@root}/origin.git"
    git "remote", "add", "origin", "#{@root}/origin.git"
    git "fetch", "--quiet", "origin"
    git "branch", "--quiet", "--set-upstream-to=origin/master"
    git "worktree", "add", "--quiet", "--track", "-b", "feat", @wt, "origin/master"
    @ws = Dashboard::Workspace.new(root: @root, prefix: "gs#{Process.pid}", base_name: "master")
    @safety = Dashboard::GitSafety::Shadows.new(env: { "XDG_RUNTIME_DIR" => @run })
  end

  def teardown
    FileUtils.rm_rf(@root)
    FileUtils.rm_rf(@run)
  end

  def test_filter_driver_never_runs
    git "config", "filter.evil.clean", evil_command
    racy("#{@base}/a.txt")
    status = ["git", "-C", @base, "status", "--porcelain=v2"]

    Dashboard::Shell.run(status, env: @safety.env(@ws))
    refute pwned?, "the clean filter ran under GitSafety"

    Dashboard::Shell.run(status, env: isolated)
    assert pwned?, "without GitSafety the attack should work"
  end

  # A submodule's own config is not the outer repo's: git status runs git in
  # the submodule, which would read its filters.
  def test_submodule_filter_never_runs
    sub = Dir.mktmpdir("git-safety-sub")
    git_in sub, "init", "--quiet"
    File.write("#{sub}/.gitattributes", "*.txt filter=evil\n")
    File.write("#{sub}/a.txt", "hi\n")
    git_in sub, "add", "."
    git_in sub, "commit", "--quiet", "--no-verify", "-m", "init"
    git "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", sub, "sub"
    git "commit", "--quiet", "--no-verify", "-m", "sub"
    git_in "#{@base}/sub", "config", "filter.evil.clean", evil_command
    racy("#{@base}/sub/a.txt")
    status = ["git", "-C", @base, "status", "--porcelain=v2", "--branch"]

    Dashboard::Shell.run(status, env: @safety.env(@ws))
    refute pwned?, "the submodule's clean filter ran under GitSafety"

    Dashboard::Shell.run(status, env: isolated)
    assert pwned?, "without GitSafety the attack should work"
  ensure
    FileUtils.rm_rf(sub)
  end

  # A container swaps master/.git/config between a version with the filter and
  # one without while the poller reads: git never sees the real file.
  def test_racing_config_writer_never_gets_a_filter_run
    racy("#{@wt}/a.txt")
    config = "#{@base}/.git/config"
    benign = File.binread(config)
    git_in @root, "config", "--file", "#{@root}/evil", "filter.evil.clean", evil_command
    evil = benign + File.binread("#{@root}/evil")
    stop = false
    swapper = Thread.new do
      until stop
        [evil, benign].each do |text|
          File.binwrite("#{config}.swap", text)
          File.rename("#{config}.swap", config)
        end
      end
    end

    read = with_git_safety(@safety) do
      200.times.count do
        S::GitStatus.fetch(@ws, @wt)
      rescue S::Failed
        false
      end
    end
    refute pwned?, "a racing config write got its filter run"
    assert_operator read, :>, 100

    # The harness: the same race against the real common dir is won.
    plain = ["git", "-C", @wt, "status", "--porcelain=v2"]
    200.times.find { Dashboard::Shell.run(plain, env: isolated.merge("GIT_OPTIONAL_LOCKS" => "0")) && pwned? }
    assert pwned?, "the race harness never got the filter to run"
  ensure
    stop = true
    swapper&.join
  end

  def test_linked_worktree_reads_through_the_shadow
    git_in @wt, "commit", "--quiet", "--no-verify", "--allow-empty", "-m", "ahead"
    File.write("#{@wt}/b.md", "two\n")

    with_git_safety(@safety) do
      info = S::GitStatus.fetch(@ws, @wt)
      assert_equal [1, 0, "origin", 1], [info.ahead, info.behind, info.upstream, info.dirty_count]
      base = S::GitStatus.fetch(@ws, @base)
      assert_equal [0, 0, "origin", 0], [base.ahead, base.behind, base.upstream, base.dirty_count]

      refs = S::Worktrees.fetch(@ws)
      assert_equal [["master", @base, true, "master"], ["wt", @wt, false, "feat"]],
                   refs.map { [it.name, it.path, it.base, it.branch] }
      assert_equal 1, S::CommitCount.fetch(@ws, @wt, "master")
      assert_equal S::Repo.parse("#{@root}/origin.git"), S::Repo.fetch(@ws)
    end
  end

  def test_shadow_config_holds_only_allowlisted_keys
    git_in @root, "config", "--file", "#{@root}/inc", "filter.evil.clean", evil_command
    { "filter.evil.clean" => evil_command, "include.path" => "#{@root}/inc", "includeIf.gitdir:/.path" => "#{@root}/inc",
      "core.fsmonitor" => evil_command, "core.hooksPath" => @root, "extensions.worktreeConfig" => "true",
      "alias.st" => "!#{evil_command}", "core.sshCommand" => evil_command }.each { |key, value| git "config", key, value }

    env = @safety.env(@ws)
    shadow = env.fetch("GIT_COMMON_DIR")
    keys = git_in(@root, "config", "--file", "#{shadow}/config", "--list", "--name-only").lines(chomp: true)

    assert_empty keys.grep(EVIL_KEYS)
    assert_includes keys, "remote.origin.url"
    assert_includes keys, "branch.feat.merge"
    assert_equal 0o700, File.stat(shadow).mode & 0o777
    refute File.exist?("#{shadow}/info")
    refute File.exist?("#{shadow}/hooks")
  end

  def test_non_regular_or_huge_config_fails_closed_without_blocking
    config = "#{@base}/.git/config"
    real = File.binread(config)
    File.binwrite("#{@root}/elsewhere", real)
    replace = [
      -> { File.mkfifo(config) },
      -> { File.symlink("#{@root}/elsewhere", config) },
      -> { File.binwrite(config, real + ("#" * (2 * 1024 * 1024))) }
    ]
    replace.each do |make|
      File.unlink(config)
      make.call
      safety = Dashboard::GitSafety::Shadows.new(env: { "XDG_RUNTIME_DIR" => @run })
      outcome = Thread.new do
        safety.env(@ws)
      rescue Dashboard::GitSafety::Unsafe => e
        e
      end
      assert outcome.join(2), "reading the config blocked"
      assert_kind_of Dashboard::GitSafety::Unsafe, outcome.value
    end
  end

  def test_a_failing_config_list_fails_closed
    with_shell(FakeShell.new("git config" => Dashboard::Shell::Result.fail("fatal: bad config line 3", status: 128))) do
      assert_raises(Dashboard::GitSafety::Unsafe) { @safety.env(@ws) }
    end
  end

  def test_overrides_stay_as_defence_in_depth
    env = @safety.env(@ws)
    pairs = Integer(env.fetch("GIT_CONFIG_COUNT")).times.to_h do |n|
      [env.fetch("GIT_CONFIG_KEY_#{n}"), env.fetch("GIT_CONFIG_VALUE_#{n}")]
    end

    assert_equal({ "core.fsmonitor" => "false", "core.hooksPath" => "/dev/null",
                   "diff.ignoreSubmodules" => "all", "submodule.recurse" => "false" }, pairs)
    assert_equal "0", env["GIT_OPTIONAL_LOCKS"]
    assert Dashboard::GitSafety::Unsafe < Dashboard::Error
  end

  private

  def evil_command = %(sh -c "touch #{@root}/PWNED; cat")
  def pwned? = File.exist?("#{@root}/PWNED")

  # Same size, same mtime: the stat data no longer matches (ctime moved), so
  # git re-hashes the file through its clean filter.
  def racy(path)
    mtime = File.mtime(path)
    File.write(path, "hu\n")
    File.utime(mtime, mtime, path)
  end

  # The developer's own git config must not change what these repos do.
  def isolated = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }

  def git(*args) = git_in(@base, *args)

  def git_in(dir, *args)
    argv = ["git", "-C", dir, "-c", "user.name=Test", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", *args]
    out, err, status = Open3.capture3(isolated, *argv)
    raise "#{argv.join(' ')}: #{err}" unless status.success?

    out
  end
end
