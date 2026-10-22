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
      build(hub:, runner: nil, token: SecureRandom.hex(32), port: ENV.fetch("WT_DASHBOARD_PORT"), ws:, github:, repo: repo_name(ws))
    end

    # owner/name from the base's origin remote, read once; the root folder's name when that fails.
    def self.repo_name(ws)
      Sources::Repo.fetch(ws)
    rescue Sources::Failed
      File.basename(ws.root)
    end

    # runner: nil until actions exist (Task 7); github: the GithubPoller, nil in tests;
    # repo: what the header shows (repo_name).
    def self.build(hub:, runner:, token:, port:, ws:, repo:, github: nil)
      app = Class.new(self)
      app.opts.merge!(hub:, runner:, token:, ws:, github:, repo:)
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

      # The page's live updates (?w=: the worktree it shows). A Rack 3 streaming
      # body: the server calls the proc with the stream and it runs until the client goes.
      r.get "events" do
        name = r.params["w"]
        name = nil unless name.is_a?(String) && !name.empty?
        opts[:github]&.hint(:focus)
        r.halt [200, { "content-type" => "text/event-stream", "cache-control" => "no-store" }, proc { |stream| events(stream, name) }]
      end

      r.post "refresh" do
        opts[:github]&.hint(:focus)
        no_content
      end
    end

    private

    def page(state, name) = Render.layout(state, token: opts[:token], repo: opts[:repo]) { Render.page(state, name, repo: opts[:repo]) }

    # Subscribes, then writes each Hub event's frames (a ping when none came for
    # Streams::PING seconds) until a write fails because the client disconnected.
    def events(stream, name)
      hub = opts[:hub]
      sub = hub.subscribe(viewing: name)
      listed = hub.snapshot.worktrees.map(&:name) # what the page's list holds
      loop do
        event = sub.queue.pop(timeout: Streams::PING)
        payload = if event
                    state = hub.snapshot
                    frames = Streams.frames(event, state, sub, listed:, repo: opts[:repo])
                    listed = state.worktrees.map(&:name) if event.first == :row # a row frame leaves the list as in state
                    frames.map { Streams.sse(it) }.join
                  else
                    Streams::PING_FRAME
                  end
        break unless payload.empty? || deliver(stream, payload)
      end
    ensure
      hub.unsubscribe(sub) if sub
      close_stream(stream)
    end

    # false when the client has gone: the write raises (which error depends on the server).
    def deliver(stream, payload)
      stream.write(payload)
      true
    rescue StandardError
      false
    end

    def close_stream(stream)
      stream.close
    rescue StandardError
      nil # the server has closed it already
    end

    # An empty 204 for a POST route's block to return. It must return nil, not
    # "": Roda drops the default content-type (which Rack forbids on a 204) only
    # when nothing was written to the body.
    def no_content
      response.status = 204
      nil
    end
  end
end
