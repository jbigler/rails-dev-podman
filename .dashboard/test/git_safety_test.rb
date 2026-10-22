# frozen_string_literal: true

require "test_helper"

class GitSafetyTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("git-safety")
    git "init", "--quiet"
    File.write("#{@dir}/.gitattributes", "*.txt filter=evil\n")
    File.write("#{@dir}/a.txt", "hi\n")
    git "add", "."
    git "commit", "--quiet", "--no-verify", "-m", "init"
  end

  def teardown = FileUtils.rm_rf(@dir)

  def test_filter_driver_never_runs
    git "config", "filter.evil.clean", %(sh -c "touch #{@dir}/PWNED; cat")
    # Same size, same mtime second: git cannot trust the stat data and re-hashes
    # a.txt through the clean filter.
    mtime = File.mtime("#{@dir}/a.txt")
    File.write("#{@dir}/a.txt", "hu\n")
    File.utime(mtime, mtime, "#{@dir}/a.txt")
    status = ["git", "-C", @dir, "status", "--porcelain=v2"]

    Dashboard::Shell.run(status, env: Dashboard::GitSafety.env(@dir))
    refute File.exist?("#{@dir}/PWNED"), "the clean filter ran under GitSafety.env"

    Dashboard::Shell.run(status, env: isolated)
    assert File.exist?("#{@dir}/PWNED"), "without GitSafety.env the attack should work"
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
    git_in "#{@dir}/sub", "config", "filter.evil.clean", %(sh -c "touch #{@dir}/PWNED; cat")
    mtime = File.mtime("#{@dir}/sub/a.txt")
    File.write("#{@dir}/sub/a.txt", "hu\n")
    File.utime(mtime, mtime, "#{@dir}/sub/a.txt")
    status = ["git", "-C", @dir, "status", "--porcelain=v2", "--branch"]

    Dashboard::Shell.run(status, env: Dashboard::GitSafety.env(@dir))
    refute File.exist?("#{@dir}/PWNED"), "the submodule's clean filter ran under GitSafety.env"

    Dashboard::Shell.run(status, env: isolated)
    assert File.exist?("#{@dir}/PWNED"), "without GitSafety.env the attack should work"
  ensure
    FileUtils.rm_rf(sub)
  end

  def test_fsmonitor_and_hooks_overridden
    env = Dashboard::GitSafety.env(@dir)
    pairs = Integer(env.fetch("GIT_CONFIG_COUNT")).times.to_h do |n|
      [env.fetch("GIT_CONFIG_KEY_#{n}"), env.fetch("GIT_CONFIG_VALUE_#{n}")]
    end

    assert_equal "false", pairs["core.fsmonitor"]
    assert_equal "/dev/null", pairs["core.hooksPath"]
    assert_equal "0", env["GIT_OPTIONAL_LOCKS"]
  end

  def test_unreadable_filter_config_fails_closed
    timed_out = Dashboard::Shell::Result.new(stdout: "", stderr: "", status: nil, timed_out: true)
    [timed_out, Dashboard::Shell::Result.fail("fatal: bad config", status: 128)].each do |result|
      with_shell(FakeShell.new("git -C #{@dir} config" => result)) do
        assert_raises(Dashboard::GitSafety::Unsafe) { Dashboard::GitSafety.env(@dir) }
      end
    end
  end

  def test_no_filter_keys_is_core_overrides_only
    with_shell(FakeShell.new("git -C #{@dir} config" => Dashboard::Shell::Result.fail("", status: 1))) do
      env = Dashboard::GitSafety.env(@dir)

      assert_equal "4", env["GIT_CONFIG_COUNT"]
      assert_equal %w[core.fsmonitor core.hooksPath diff.ignoreSubmodules submodule.recurse], 4.times.map { env["GIT_CONFIG_KEY_#{it}"] }
      assert Dashboard::GitSafety::Unsafe < Dashboard::Error
    end
  end

  private

  # The developer's own git config must not change what these repos do.
  def isolated = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }

  def git(*args) = git_in(@dir, *args)

  def git_in(dir, *args)
    argv = ["git", "-C", dir, "-c", "user.name=Test", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", *args]
    _out, err, status = Open3.capture3(isolated, *argv)
    raise "#{argv.join(' ')}: #{err}" unless status.success?
  end
end
