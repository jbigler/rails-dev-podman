# frozen_string_literal: true

require_relative "test_helper"
require "rack/lint"
require "rack/test"

# The task palette: the mise task list, where each task runs, and its route.
class PaletteTest < Minitest::Test
  include Rack::Test::Methods

  P = Dashboard::Palette
  POST = { "HTTP_HOST" => "wt.localhost:7700", "HTTP_ORIGIN" => "http://wt.localhost:7700", "HTTP_X_DASHBOARD_TOKEN" => "t" }.freeze
  GET = { "HTTP_HOST" => "wt.localhost:7700" }.freeze

  def setup
    P.reset
    @shell_was = Dashboard::Shell.backend
    @shell = FakeShell.new("mise tasks --json" => Dashboard::Shell::Result.new(stdout: fixture("mise-tasks.json"), stderr: "", status: 0, timed_out: false))
    Dashboard::Shell.backend = @shell
  end

  def teardown
    runner.jobs.select(&:running?).each { runner.cancel(it.id) } if @runner
    Dashboard::Shell.backend = @shell_was
    P.reset
  end

  def hub = @hub ||= Dashboard::Hub.new(ws, raw: fixture_raw)
  def spawner = @spawner ||= FakeSpawner.new
  def runner = @runner ||= Dashboard::Runner.new(hub:, ws:, spawner:)

  def app
    @app ||= Rack::Lint.new(Dashboard::App.build(hub:, runner:, token: "t", port: 7700, ws:, repo: "example-org/app"))
  end

  def test_palette_lists_mise_tasks
    expected = JSON.parse(fixture("mise-tasks.json")).reject { it["hide"] }.map { it["name"] }
    assert_equal expected, P.tasks(ws).map(&:name)
  end

  def test_listing_runs_at_the_workspace_root_and_is_cached
    2.times { P.tasks(ws) }
    calls = @shell.calls.select { it.argv == %w[mise tasks --json] }
    assert_equal [ROOT], calls.map(&:chdir)
  end

  def test_palette_routes_interactive_to_terminal
    assert_equal :terminal, P.mode("console")
    assert_equal :stream, P.mode("test:rails")
  end

  def test_argv_splits_input
    task = P.tasks(ws).find { it.name == "test:rails" }
    assert_equal ["mise", "run", "test:rails", "-n", "foo bar"], P.argv(task, %(-n "foo bar"))
  end

  def test_palette_unbalanced_quote
    post "/w/wt-01/palette", { task: "test:rails", args: %(-n "foo) }, POST
    assert_equal 422, last_response.status
    assert_includes last_response.body, "Unmatched quote"
  end

  def test_palette_required_args
    post "/w/wt-01/palette", { task: "wt", args: "" }, POST
    assert_equal 422, last_response.status
    assert_includes last_response.body, "arguments required"
  end

  def test_palette_runs_task_in_the_worktree
    post "/w/wt-01/palette", { task: "console", args: "" }, POST
    assert_equal 202, last_response.status
    job = runner.jobs.find { it.id.to_s == last_response.body }
    assert job
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.001 while spawner.calls.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    call = spawner.calls.last
    assert_includes call.argv, ws.newterm
    assert_equal %w[mise run console], call.argv.last(3)
  end

  def test_palette_unknown_task
    post "/w/wt-01/palette", { task: "nope", args: "" }, POST
    assert_equal 404, last_response.status
  end

  def test_palette_list_fragment
    get "/palette", { w: "wt-01" }, GET
    assert_equal 200, last_response.status
    body = last_response.body
    assert_includes body, "test:rails"
    assert_includes body, %(data-palette-args="required")
    assert_includes body, "/w/wt-01/palette"
  end

  def test_workspace_tasks_run_at_the_root_one_at_a_time
    assert_equal :workspace, P.spec("wt", %w[mise run wt x]).scope
    assert_equal :workspace, P.spec("proxy:up", %w[mise run proxy:up]).scope
    assert_equal :worktree, P.spec("test:rails", %w[mise run test:rails]).scope

    post "/w/wt-01/palette", { task: "wt", args: "feature/x" }, POST
    assert_equal 202, last_response.status
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.001 while spawner.calls.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    call = spawner.calls.last
    assert_equal ROOT, call.chdir
    assert_equal %w[mise run wt feature/x], call.argv.last(4)
  end

  def test_destructive_tasks_are_marked_for_a_confirm
    %w[units:uninstall dashboard:stop wt:rm db:dump:clear].each { assert P.confirm?(it), it }
    refute P.confirm?("test:rails")

    get "/palette", { w: "wt-01" }, GET
    body = last_response.body
    assert_includes body, %(data-palette-name="wt:rm" data-palette-confirm)
    refute_includes body, %(data-palette-name="test:rails" data-palette-confirm)
  end
end
