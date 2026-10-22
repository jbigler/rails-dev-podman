# frozen_string_literal: true

require "test_helper"

class PrivateDirTest < Minitest::Test
  P = Dashboard::PrivateDir

  def setup = @run = Dir.mktmpdir("private-dir")
  def teardown = FileUtils.rm_rf(@run)

  def test_created_in_the_runtime_dir_mode_0700
    path = P.for("pd", env: { "XDG_RUNTIME_DIR" => @run })
    assert_equal "#{@run}/pd-dashboard", path
    assert_equal 0o700, File.stat(path).mode & 0o777
    assert_equal path, P.for("pd", env: { "XDG_RUNTIME_DIR" => @run })
  end

  def test_falls_back_to_a_per_user_tmp_dir
    prefix = "pd#{Process.pid}"
    path = P.for(prefix, env: {})
    assert_equal File.join(Dir.tmpdir, "#{prefix}-dashboard-#{Process.uid}"), path
    assert_equal 0o700, File.stat(path).mode & 0o777
  ensure
    FileUtils.rm_rf(path) if path
  end

  def test_refuses_an_open_dir_or_a_symlink
    Dir.mkdir("#{@run}/open-dashboard", 0o755)
    File.chmod(0o755, "#{@run}/open-dashboard")
    Dir.mkdir("#{@run}/target", 0o700)
    File.symlink("#{@run}/target", "#{@run}/link-dashboard")

    assert_raises(Dashboard::Error) { P.for("open", env: { "XDG_RUNTIME_DIR" => @run }) }
    assert_raises(Dashboard::Error) { P.for("link", env: { "XDG_RUNTIME_DIR" => @run }) }
  end
end
