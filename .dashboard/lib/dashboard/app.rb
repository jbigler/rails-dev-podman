# frozen_string_literal: true

require "roda"
require "securerandom"

module Dashboard
  # The routes. Each build is a subclass holding its hub, runner and token in
  # opts, behind the Guard.
  class App < Roda
    PUBLIC = File.expand_path("../../public", __dir__)

    plugin :public, root: PUBLIC
    plugin :default_headers, "content-type" => "text/html; charset=utf-8"

    # The app the unit serves: the workspace found from the working directory,
    # the pollers running, a token new at every start.
    def self.boot
      ws = Workspace.discover
      hub = Hub.new(ws)
      schedule = Schedule.new(Time.now)
      LocalPoller.new(hub, ws, schedule).start
      github = GithubPoller.new(hub, ws, schedule).start
      build(hub:, runner: nil, token: SecureRandom.hex(32), port: ENV.fetch("WT_DASHBOARD_PORT"), ws:, github:)
    end

    # runner: nil until actions exist (Task 7); github: the GithubPoller, nil in tests.
    def self.build(hub:, runner:, token:, port:, ws:, github: nil)
      app = Class.new(self)
      app.opts.merge!(hub:, runner:, token:, ws:, github:)
      Guard.new(app.freeze.app, port:, token:)
    end

    route do |r|
      r.on("assets") { r.public }
      r.get("healthz") { "ok" }

      r.root do
        state = opts[:hub].snapshot
        first = state.worktrees.first
        r.redirect Render.path(first.name) if first
        page(state, nil)
      end

      r.get "w", String do |encoded|
        name = Rack::Utils.unescape_path(encoded)
        state = opts[:hub].snapshot
        r.redirect "/" unless state.worktrees.any? { it.name == name }
        page(state, name)
      end

      r.post "refresh" do
        opts[:github]&.hint(:focus)
        response.status = 204
        ""
      end
    end

    private

    def page(state, name) = Render.layout(state, token: opts[:token]) { Render.page(state, name) }
  end
end
