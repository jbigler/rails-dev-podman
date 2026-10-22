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
    # the children's environment captured, the pollers running, a token new at
    # every start.
    def self.boot
      ChildEnv.base
      ws = Workspace.discover
      hub = Hub.new(ws)
      schedule = Schedule.new(Time.now)
      local = LocalPoller.new(hub, ws, schedule).start
      github = GithubPoller.new(hub, ws, schedule).start
      runner = Runner.new(hub:, ws:, github:, local:)
      build(hub:, runner:, token: SecureRandom.hex(32), port: ENV.fetch("WT_DASHBOARD_PORT"), ws:, github:, repo: repo_name(ws))
    end

    # owner/name from the base's origin remote, read once; the root folder's name when that fails.
    def self.repo_name(ws)
      Sources::Repo.fetch(ws)
    rescue Sources::Failed
      File.basename(ws.root)
    end

    # runner: the Runner (nil in tests that start no action); github: the
    # GithubPoller, nil in tests; repo: what the header shows (repo_name).
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

      # A worktree's action (form: input, discard) → 202 with the job id.
      r.post "w", String, "act", String do |encoded, id|
        name = Rack::Utils.unescape_path(encoded)
        wt = opts[:hub].snapshot.worktrees.find { it.name == name }
        spec = Actions.find(id)
        not_found unless wt && spec&.target == :worktree
        refuse(422, "not on the base worktree") if wt.base && !spec.base_ok
        start(spec, wt)
      end

      r.post "act", String do |id|
        spec = Actions.find(id)
        not_found unless spec&.target == :workspace
        start(spec, nil)
      end

      # The palette's list for worktree ?w= (name, description, argument kind).
      r.get "palette" do
        name = r.params["w"].to_s
        not_found unless opts[:hub].snapshot.worktrees.any? { it.name == name }
        Render.palette(Palette.tasks(opts[:ws]), name)
      rescue Sources::Failed => e
        refuse(502, e.message)
      end

      # A palette task (form: task, args) in the worktree → 202 with the job id.
      r.post "w", String, "palette" do |encoded|
        name = Rack::Utils.unescape_path(encoded)
        wt = opts[:hub].snapshot.worktrees.find { it.name == name }
        task = Palette.tasks(opts[:ws]).find { it.name == r.params["task"] }
        refuse(404, "no such task") unless wt && task
        argv = Palette.argv(task, r.params["args"])
        job = opts[:runner].start(Palette.spec(task.name, argv), worktree: wt)
        response.status = 202
        text(job.id.to_s)
      rescue Palette::BadArgs => e
        refuse(422, e.message)
      rescue Sources::Failed => e
        refuse(502, e.message)
      rescue Runner::Busy => e
        refuse(409, e.message)
      end

      r.post "jobs", Integer, "cancel" do |id|
        not_found unless opts[:runner].cancel(id)
        no_content
      end
    end

    private

    def page(state, name) = Render.layout(state, token: opts[:token], repo: opts[:repo]) { Render.page(state, name, repo: opts[:repo]) }

    # Subscribes, sends the catch-up frames, then writes each Hub event's frames (a
    # ping when none came for Streams::PING seconds) until a write fails because the
    # client disconnected.
    def events(stream, name)
      hub = opts[:hub]
      sub = hub.subscribe(viewing: name)
      state = hub.snapshot # after subscribe: any later change is queued
      listed = state.worktrees.map(&:name) # what the page's list holds once the catch-up lands
      jobs = Streams.shown_jobs(state) # and its action panel
      return unless deliver(stream, Streams.catch_up(state, sub, repo: opts[:repo]).map { Streams.sse(it) }.join)

      loop do
        event = sub.queue.pop(timeout: Streams::PING)
        payload = if event
                    state = hub.snapshot
                    frames = Streams.frames(event, state, sub, listed:, jobs:, repo: opts[:repo])
                    listed = state.worktrees.map(&:name) if event.first == :row # a row frame leaves the list as in state
                    jobs = Streams.shown_jobs(state, jobs, event[1]) if event.first == :job
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

    # Starts the spec with the request's input (stripped; required when the spec
    # prompts) → the job id as text/plain, 409 while busy.
    def start(spec, wt)
      input = request.params["input"].to_s.strip
      refuse(422, "#{spec.label}: an answer is required") if spec.prompt && input.empty?
      job = opts[:runner].start(spec, worktree: wt, input: (input if spec.prompt), discard: request.params["discard"] == "1")
      response.status = 202
      text(job.id.to_s)
    rescue Runner::Busy => e
      refuse(409, e.message)
    end

    def not_found = refuse(404, "no such action")
    def refuse(status, message) = request.halt([status, { "content-type" => "text/plain" }, [message]])

    def text(body)
      response["content-type"] = "text/plain"
      body
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
