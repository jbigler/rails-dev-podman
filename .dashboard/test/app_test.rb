# frozen_string_literal: true

require "test_helper"
require "rack/lint"
require "rack/test"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  HOST = { "HTTP_HOST" => "wt.localhost:7700" }.freeze
  ORIGIN = "http://wt.localhost:7700"

  # Records the hints POST /refresh sends.
  class FakeGithub
    attr_reader :hints

    def initialize = @hints = []
    def hint(kind) = @hints << kind
  end

  # Through Rack::Lint, so a response that breaks the Rack SPEC fails the test.
  def app
    @app ||= Rack::Lint.new(Dashboard::App.build(hub: Dashboard::Hub.new(ws, raw: @raw || fixture_raw), runner: nil, token: "t", port: 7700,
                                                 ws:, github: @github, repo: "example-org/app"))
  end

  def test_header_shows_repo
    get "/w/wt-01", {}, HOST
    assert_includes last_response.body, '<span class="repo">example-org/app</span>'
  end

  def test_repo_name_from_origin_else_root_folder
    master = "#{ROOT}/master"
    remote = { "git -C #{master} remote get-url origin" => Dashboard::Shell::Result.new(stdout: "git@github.com:example-org/app.git\n", stderr: "",
                                                                                         status: 0, timed_out: false) }
    with_shell(FakeShell.new(remote)) { assert_equal "example-org/app", Dashboard::App.repo_name(ws) }
    with_shell(FakeShell.new) { assert_equal "myproj", Dashboard::App.repo_name(ws) }
  end

  def test_lists_every_worktree
    get "/w/wt-stacked", {}, HOST
    assert_equal 200, last_response.status
    assert_equal 16, last_response.body.scan(/id="row-[^"]+"/).size
    assert_includes last_response.body, "◀ HEAD"
    assert_includes last_response.body, "✓ 5 merged"
  end

  def test_rejects_foreign_host
    get "/w/wt-stacked", {}, "HTTP_HOST" => "evil.example:7700"
    assert_equal 403, last_response.status
    assert_equal "forbidden host", last_response.body
    get "/w/wt-stacked", {}, "HTTP_HOST" => "wt.localhost:80"
    assert_equal 403, last_response.status
    get "/healthz", {}, "HTTP_HOST" => "127.0.0.1:7700"
    assert_equal 200, last_response.status
    assert_equal "ok", last_response.body
  end

  def test_post_needs_token_and_origin
    @github = FakeGithub.new
    post "/refresh", {}, HOST
    assert_equal 403, last_response.status
    post "/refresh", {}, HOST.merge("HTTP_X_DASHBOARD_TOKEN" => "t", "HTTP_ORIGIN" => "http://evil.example")
    assert_equal 403, last_response.status
    assert_nil last_response.headers["x-dashboard-reload"]
    assert_empty @github.hints
    post "/refresh", {}, HOST.merge("HTTP_X_DASHBOARD_TOKEN" => "t", "HTTP_ORIGIN" => ORIGIN)
    assert_equal 204, last_response.status
    assert_nil last_response.headers["content-type"]
    assert_equal [:focus], @github.hints
  end

  def test_stale_token_asks_for_reload
    post "/refresh", {}, HOST.merge("HTTP_X_DASHBOARD_TOKEN" => "old", "HTTP_ORIGIN" => ORIGIN)
    assert_equal 403, last_response.status
    assert_equal "1", last_response.headers["x-dashboard-reload"]
  end

  def test_unusual_worktree_name
    raw = fixture_raw
    odd = Dashboard::WorktreeRef.new(name: "app.v2<x>", path: "#{ROOT}/app.v2<x>", branch: "feature/odd", head_sha: "abc", base: false)
    @raw = raw.with(refs: raw.refs + [odd])
    get "/w/wt-01", {}, HOST
    body = last_response.body
    assert_includes body, "app.v2&lt;x&gt;"
    refute_includes body, "app.v2<x>"
    assert_includes body, 'href="/w/app.v2%3Cx%3E"'
    assert_includes body, 'id="row-app_2ev2_3cx_3e"'
    get "/w/app.v2%3Cx%3E", {}, HOST
    assert_equal 200, last_response.status
  end

  def test_unknown_worktree_redirects
    get "/w/nope", {}, HOST
    assert_equal 302, last_response.status
    assert_equal "/", last_response.headers["location"]
  end

  def test_root_redirects_to_first_worktree
    get "/", {}, HOST
    assert_equal 302, last_response.status
    assert_equal "/w/wt-01", last_response.headers["location"]
  end

  def test_page_carries_token_and_import_map
    get "/w/wt-01", {}, HOST
    body = last_response.body
    assert_includes body, '<meta name="dashboard-token" content="t">'
    assert_includes body, '"@hotwired/turbo": "/assets/vendor/turbo.es2017-esm.js"'
    assert_includes body, '<script type="module" src="/assets/app.js"></script>'
  end

  def test_serves_assets
    get "/assets/app.js", {}, HOST
    assert_equal 200, last_response.status
    assert_includes last_response.body, "@hotwired/stimulus"
    get "/assets/vendor/turbo.es2017-esm.js", {}, HOST
    assert_equal 200, last_response.status
  end
end
