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

  def test_fsmonitor_and_hooks_overridden
    env = Dashboard::GitSafety.env(@dir)
    pairs = Integer(env.fetch("GIT_CONFIG_COUNT")).times.to_h do |n|
      [env.fetch("GIT_CONFIG_KEY_#{n}"), env.fetch("GIT_CONFIG_VALUE_#{n}")]
    end

    assert_equal "false", pairs["core.fsmonitor"]
    assert_equal "/dev/null", pairs["core.hooksPath"]
    assert_equal "0", env["GIT_OPTIONAL_LOCKS"]
  end

  private

  # The developer's own git config must not change what these repos do.
  def isolated = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1" }

  def git(*args)
    argv = ["git", "-C", @dir, "-c", "user.name=Test", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", *args]
    _out, err, status = Open3.capture3(isolated, *argv)
    raise "#{argv.join(' ')}: #{err}" unless status.success?
  end
end
