# frozen_string_literal: true

module Dashboard
  # What both pollers share: a fetch's result, or its failure, into the Hub.
  module Polling
    TICK = 0.25

    private

    # A raised Sources::Failed keeps the previous value and marks the key failed.
    def read(key)
      @hub.apply(key, yield)
    rescue Sources::Failed => e
      @hub.apply(key, nil, failed: e.message)
    end

    # A bug in one source must not end the thread: logged, and the loop goes on.
    def guarded
      yield
    rescue StandardError => e
      warn "dashboard: #{self.class.name}: #{e.class}: #{e.message}"
    end
  end

  # Reads git, systemd, podman and the files under ROOT into the Hub on its
  # own thread, as the Schedule says.
  class LocalPoller
    include Polling

    def initialize(hub, ws, schedule)
      @hub = hub
      @ws = ws
      @schedule = schedule
      @wake = Thread::Queue.new
    end

    def start
      Thread.new { run }.name = "local-poller"
      self
    end

    # Every local source runs on the next iteration, which starts now (after an action).
    def poke
      @wake << :poke
      nil
    end

    # Reads one source now.
    def refresh(key)
      raw = @hub.snapshot.raw
      refs = raw.refs || []
      names = refs.map(&:name)
      case key
      when :worktrees then read(:worktrees) { Sources::Worktrees.fetch(@ws) }
      when :git then refs.each { |ref| read([:git, ref.name]) { Sources::GitStatus.fetch(ref.path) } }
      when :units then read(:units) { Sources::Units.fetch(units(names)) }
      when :containers then read(:containers) { Sources::Containers.fetch }
      when :agent_files then read(:agent_files) { Sources::AgentFiles.fetch(@ws, names, mtimes(raw.agent_files)) }
      when :unit_env then read(:unit_env) { Sources::UnitEnv.fetch(@ws, names, mtimes(raw.env)) }
      when :stale_units then read(:stale_units) { Sources::StaleUnits.fetch(@ws) }
      when :autostart then read(:autostart) { Sources::Autostart.fetch(@ws) }
      else raise ArgumentError, "unknown local source: #{key.inspect}"
      end
    end

    private

    def run
      poked = false
      loop do
        now = Time.now
        (poked ? @schedule.local_all(now) : @schedule.local_due(now)).each { |key| guarded { refresh(key) } }
        poked = !@wake.pop(timeout: TICK).nil?
        @wake.clear
      end
    end

    # The six service units of every worktree.
    def units(names) = names.flat_map { |n| Workspace::SERVICES.map { |_, svc| @ws.unit(svc, n) } }

    # name => [mtime, value] → name => mtime, what Sources.reread already holds.
    def mtimes(cache) = cache.transform_values(&:first)
  end

  # Reads GitHub into the Hub on its own thread: at startup, on hints, and on
  # the Schedule's timer while a page is open. Open PRs every time; the
  # all-states index only on demand (startup and hints), never on the timer;
  # the stack and the open PR's commit count for viewed worktrees only.
  class GithubPoller
    include Polling

    # Pending checks on any open PR, or an open PR on a viewed worktree, make
    # the timer run every Schedule::HOT seconds.
    def self.hot?(raw, viewed)
      raw.prs.each_value.any? { it.checks && it.checks[:pending].positive? } ||
        (raw.refs || []).any? { viewed.include?(it.name) && raw.prs.key?(it.branch) }
    end

    def initialize(hub, ws, schedule, clock: Time.method(:now))
      @hub = hub
      @ws = ws
      @schedule = schedule
      @clock = clock
      @lock = Mutex.new # guards @schedule and @pending: hints arrive on request threads
      @wake = Thread::Queue.new
      @pending = true # the startup refresh
    end

    def start
      Thread.new { run }.name = "github-poller"
      self
    end

    # kind: :focus (a page connected or regained focus) or :action (an action
    # that touches GitHub finished). → the Schedule's :run, :drop or :queued.
    def hint(kind)
      verdict = @lock.synchronize do
        @schedule.hint(@clock.call, kind).tap { @pending = true if it == :run }
      end
      @wake << verdict if verdict == :run
      verdict
    end

    # One step: the startup or hinted refresh (with the index), else the
    # timer's when due; again while actions queue reruns.
    def tick
      hot = self.class.hot?(@hub.snapshot.raw, @hub.viewed_names)
      subscribers = @hub.subscriber_count
      full = @lock.synchronize do
        now = @clock.call
        if @pending || @schedule.github_due?(now, subscribers:, hot:)
          @schedule.github_started(now)
          on_demand = @pending
          @pending = false
          on_demand
        end
      end
      return if full.nil?

      loop do
        guarded { refresh(full:) }
        break unless @lock.synchronize { @schedule.github_finished(@clock.call) }

        full = true
      end
    end

    # full: also the all-states PR index.
    def refresh(full:)
      read(:prs) { Sources::OpenPrs.fetch(@ws) }
      read(:pr_index) { Sources::PrIndex.fetch(@ws) } if full
      viewed = @hub.viewed_names
      raw = @hub.snapshot.raw
      (raw.refs || []).select { viewed.include?(it.name) }.each do |ref|
        read([:stacks, ref.name]) { Sources::Stack.fetch(ref.path) }
        pr = raw.prs[ref.branch]
        read([:commits, ref.name]) { Sources::CommitCount.fetch(ref.path, pr.base_ref) } if pr
      end
    end

    private

    def run
      loop do
        guarded { tick }
        @wake.pop(timeout: TICK)
      end
    end
  end
end
