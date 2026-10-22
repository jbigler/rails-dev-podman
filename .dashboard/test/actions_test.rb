# frozen_string_literal: true

require_relative "test_helper"
require "rack/lint"
require "rack/test"

# The registry, the session environment, the action routes and their buttons.
class ActionsTest < Minitest::Test
  include Rack::Test::Methods

  A = Dashboard::Actions
  POST = { "HTTP_HOST" => "wt.localhost:7700", "HTTP_ORIGIN" => "http://wt.localhost:7700", "HTTP_X_DASHBOARD_TOKEN" => "t" }.freeze

  def setup
    @shell_was = Dashboard::Shell.backend
    Dashboard::Shell.backend = FakeShell.new
  end

  def teardown
    Dashboard::Shell.backend = @shell_was
  end

  def hub = @hub ||= Dashboard::Hub.new(ws, raw: @raw || fixture_raw)
  def spawner = @spawner ||= FakeSpawner.new(hold: ["mise run up", "mise run units:install"])
  def runner = @runner ||= Dashboard::Runner.new(hub:, ws:, spawner:)
  def wt(name) = hub.snapshot.worktrees.find { it.name == name }

  def app
    @app ||= Rack::Lint.new(Dashboard::App.build(hub:, runner:, token: "t", port: 7700, ws:, repo: "example-org/app"))
  end

  # Cancels every running job, so none outlives the test.
  def release_all
    runner.jobs.select(&:running?).each { runner.cancel(it.id) }
    settle
  end

  # Waits (up to a second) until no job runs.
  def settle
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.001 until runner.jobs.none?(&:running?) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    refute runner.jobs.any?(&:running?), "a job still runs after 1 s"
  end

  def argv(id, name = "wt-01", input = nil) = A.find(id).argv.(ws, name && wt(name), input)

  def test_down_is_forced
    assert_equal({ "FORCE" => "1" }, A.find("down").env)
    assert_equal({}, A.find("wt-rm").environment(false))
    assert_equal({ "FORCE" => "1" }, A.find("wt-rm").environment(true))
    assert_equal({}, A.find("up").environment(true))
  end

  def test_registry_commands
    assert_equal [%w[mise run up]], argv("up")
    assert_equal [%w[mise run restart db]], argv("restart-db")
    assert_equal [%w[mise run stop], %w[mise run up]], argv("restart-all")
    assert_equal [%w[mise run test:rails_system]], argv("test-system")
    assert_equal [%w[mise run rails]], argv("shell")
    assert_equal [%w[gh stack push]], argv("stack-push")
    assert_equal [%w[mise run wt:rm wt-01]], argv("wt-rm")
    assert_equal [%w[mise run wt feature/x]], argv("wt-create", nil, "feature/x")
    assert_equal [%w[mise run dashboard:autostart off]], argv("autostart-off", nil)
    assert_equal :terminal, A.find("restack").mode
    assert_equal %i[workspace workspace], [A.find("wt-rm").scope, A.find("wt-create").scope]
    assert A.find("stack-push").github
    assert_nil A.find("nope")
  end

  def test_for_worktree_leaves_wt_rm_off_the_base
    ids = A.for_worktree(wt("wt-01")).map(&:id)
    assert_includes ids, "wt-rm"
    assert_includes ids, "restart-nvim"
    refute_includes ids, "wt-create"
    refute_includes A.for_worktree(wt("master")).map(&:id), "wt-rm"
  end

  def test_session_env_from_manager
    shell = FakeShell.new("systemctl --user show-environment" => Dashboard::Shell::Result.ok("DISPLAY=:0\nSSH_AUTH_SOCK=/run/user/1000/ssh\nFOO=x\n"))
    with_shell(shell) do
      assert_equal({ "DISPLAY" => ":0", "SSH_AUTH_SOCK" => "/run/user/1000/ssh", "NO_COLOR" => "1" }, Dashboard::SessionEnv.current)
    end
    quoted = FakeShell.new("systemctl --user show-environment" => Dashboard::Shell::Result.ok("DISPLAY=$'a b\\'c'\n"))
    with_shell(quoted) { assert_equal "a b'c", Dashboard::SessionEnv.current["DISPLAY"] }
    with_shell(FakeShell.new) { assert_equal({ "NO_COLOR" => "1" }, Dashboard::SessionEnv.current) }
  end

  def test_wt_rm_refused_on_base
    post "/w/master/act/wt-rm", {}, POST
    assert_equal 422, last_response.status
    assert_empty runner.jobs
  end

  def test_start_is_accepted_then_busy
    post "/w/wt-01/act/up", {}, POST
    assert_equal 202, last_response.status
    assert_equal "text/plain", last_response.headers["content-type"]
    id = Integer(last_response.body)
    assert_equal "up", runner.jobs.find { it.id == id }.label
    post "/w/wt-01/act/up", {}, POST
    assert_equal 409, last_response.status
  ensure
    release_all
  end

  def test_unknown_or_misplaced_actions
    post "/w/wt-01/act/nope", {}, POST
    assert_equal 404, last_response.status
    post "/w/nope/act/up", {}, POST
    assert_equal 404, last_response.status
    post "/w/wt-01/act/wt-create", { input: "x" }, POST
    assert_equal 404, last_response.status
    post "/act/up", {}, POST
    assert_equal 404, last_response.status
  end

  def test_workspace_action_needs_its_input
    post "/act/wt-create", { input: "  " }, POST
    assert_equal 422, last_response.status
    post "/act/units-install", {}, POST
    assert_equal 202, last_response.status
    assert_nil runner.jobs.last.worktree
  ensure
    release_all
  end

  def test_discard_reaches_wt_rm
    post "/w/wt-02/act/wt-rm", { discard: "1" }, POST
    assert_equal 202, last_response.status
    settle
    assert_equal "1", spawner.calls.last.env["FORCE"]
  end

  def test_cancel_route
    post "/w/wt-01/act/up", {}, POST
    id = last_response.body
    post "/jobs/#{id}/cancel", {}, POST
    assert_equal 204, last_response.status
    assert_nil last_response.headers["content-type"]
    release_all
    assert_equal :cancelled, runner.jobs.last.state
    post "/jobs/#{id}/cancel", {}, POST
    assert_equal 404, last_response.status
  end

  # A branch of the stack's open list switches the worktree to it; the
  # current branch, a merged one, the trunk or anything else is refused.
  def test_stack_switch_takes_only_an_open_stack_branch
    assert_equal [["git", "switch", "--no-guess", "feature/branch-15"]], argv("stack-switch", "wt-stacked", "feature/branch-15")
    ["feature/branch-72", "feature/branch-50", "master", "--orphan=x", ""].each do |branch|
      post "/w/wt-stacked/act/stack-switch", { input: branch }, POST
      assert_equal 422, last_response.status, branch
    end
    post "/w/wt-01/act/stack-switch", { input: "feature/branch-15" }, POST
    assert_equal 422, last_response.status
    assert_empty runner.jobs

    post "/w/wt-stacked/act/stack-switch", { input: "feature/branch-15" }, POST
    assert_equal 202, last_response.status
    settle
    assert_equal ["git", "switch", "--no-guess", "feature/branch-15"], spawner.calls.last.argv.last(4)
  end

  def test_header_buttons
    @raw = fixture_raw.with(stale_units: ["a.container\tdiffers"], autostart: :enabled)
    html = Dashboard::Render.header(hub.snapshot, repo: "r")
    assert_includes html, 'data-action-url-param="/act/units-install"'
    assert_includes html, 'data-action-url-param="/act/wt-create"'
    assert_includes html, 'data-action-url-param="/act/autostart-off"'
    assert_includes html, 'aria-checked="true"'
    @hub = nil
    @raw = fixture_raw.with(autostart: :unknown)
    html = Dashboard::Render.header(hub.snapshot, repo: "r")
    refute_includes html, "/act/units-install"
    assert_includes html, 'data-action-url-param="/act/autostart-on"'
    assert_includes html, 'aria-checked="false"'
  end

  def test_detail_buttons_and_busy_state
    html = Dashboard::Render.detail(wt("wt-01"), hub.snapshot)
    assert_includes html, 'data-action-url-param="/w/wt-01/act/up"'
    assert_includes html, 'data-action-url-param="/w/wt-01/act/restart-db"'
    assert_includes html, 'data-action-discard-param="true"'
    refute_includes html, " disabled"
    refute_includes Dashboard::Render.detail(wt("master"), hub.snapshot), "/act/wt-rm"
    runner.start(A.find("up"), worktree: wt("wt-01"))
    busy = Dashboard::Render.detail(wt("wt-01"), hub.snapshot)
    assert_equal busy.scan("data-action-url-param=").size, busy.scan(" disabled").size
    refute_includes Dashboard::Render.detail(wt("wt-02"), hub.snapshot), " disabled"
  ensure
    release_all
  end

  def test_stack_branches_are_switch_buttons
    html = Dashboard::Render.detail(wt("wt-stacked"), hub.snapshot)
    assert_includes html, 'data-action-input-param="feature/branch-15"'
    refute_includes html, 'data-action-input-param="feature/branch-72"' # HEAD
    refute_includes html, 'data-action-input-param="feature/branch-50"' # merged
    assert_equal 1, html.scan(/<button[^>]*data-action-input-param="feature\/branch-15"/).size
  end
end
