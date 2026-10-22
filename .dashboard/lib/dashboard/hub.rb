# frozen_string_literal: true

module Dashboard
  # What every page renders from. failed: failure key ("units", "stacks:<W>") => message.
  State = Data.define(:worktrees, :raw, :failed, :jobs) do
    # Worktrees whose agent waits on a permission or a question (header and <title>).
    def needs_input_count = worktrees.count { it.agent.is_a?(Agent) && it.agent.needs_input? }
  end

  # One page's event stream. viewing: the worktree its detail pane shows (nil
  # for none); changed only through Hub#view.
  class Subscription
    attr_reader :queue
    attr_accessor :viewing

    def initialize(viewing)
      @queue = Thread::Queue.new
      @viewing = viewing
    end
  end

  # Holds the State. Every source result goes through #apply, which merges it
  # into Raw, re-derives the worktrees and queues what changed for each page:
  # [:row, W] to all (W added, changed or removed), [:detail, W] to pages
  # viewing W, [:gone, W] to pages viewing a removed W, [:notify, W] to all
  # when W's agent starts waiting on a permission or a question, [:header] to
  # all when the needs-input count, the stale units or autostart changed.
  # Jobs come from the Runner through #publish_job: [:job, id] to all.
  class Hub
    # sources whose value replaces the Raw field of the same name (:worktrees replaces refs)
    REPLACE = %i[units containers stale_units autostart prs pr_index].freeze
    # source => the Raw field its { changed:, gone: } result (Sources.reread) updates
    REREAD = { unit_env: :env, agent_files: :agent_files }.freeze
    # sources applied one worktree at a time, as [source, name]
    PER_WORKTREE = %i[git stacks commits].freeze
    # Raw fields keyed by worktree name, cut back to the current refs
    BY_NAME = %i[git env agent_files commits stacks].freeze
    # jobs State#jobs keeps; the oldest finished ones go first
    KEEP_JOBS = 20

    # raw: the results to start from (tests feed fixture_raw).
    def initialize(ws, raw: Raw.empty)
      @ws = ws
      @lock = Mutex.new
      @subs = []
      @state = State.new(worktrees: Derive.worktrees(ws, raw, {}), raw:, failed: {}, jobs: [])
    end

    # key: a source (:worktrees, :units, :unit_env, …) or [source, name] for
    # one worktree's :git, :stacks or :commits. failed: the Sources::Failed
    # message; the previous value stays and the key is marked failed until it
    # reads again. New refs drop the values and failures of removed worktrees.
    def apply(key, value, failed: false)
      @lock.synchronize do
        old = @state
        failure = Array(key).join(":")
        raw = failed ? old.raw : merge(old.raw, key, value)
        failures = failed ? old.failed.merge(failure => failed) : old.failed.except(failure)
        failures = current(failures, raw.refs) if key == :worktrees && !failed
        @state = old.with(worktrees: Derive.worktrees(@ws, raw, failures), raw:, failed: failures)
        publish(old, @state)
      end
      nil
    end

    # job: a frozen copy. Replaces the job with its id in place, else appends it (newest last).
    def publish_job(job)
      @lock.synchronize do
        jobs = @state.jobs.dup
        index = jobs.index { it.id == job.id }
        index ? jobs[index] = job : jobs << job
        while jobs.size > KEEP_JOBS && (finished = jobs.index { !it.running? })
          jobs.delete_at(finished)
        end
        @state = @state.with(jobs: jobs.freeze)
        send_to(@subs, [:job, job.id])
      end
      nil
    end

    def snapshot = @lock.synchronize { @state }

    def subscribe(viewing:)
      sub = Subscription.new(viewing)
      @lock.synchronize { @subs << sub }
      sub
    end

    def unsubscribe(sub)
      @lock.synchronize { @subs.delete(sub) }
      nil
    end

    def view(sub, name)
      @lock.synchronize { sub.viewing = name }
    end

    def viewed_names = @lock.synchronize { @subs.filter_map(&:viewing).to_set }
    def subscriber_count = @lock.synchronize { @subs.size }

    private

    def merge(raw, key, value)
      source, name = key
      raise ArgumentError, "unknown source: #{key.inspect}" if PER_WORKTREE.include?(source) == name.nil?

      if name
        raw.with(source => raw.public_send(source).merge(name => value))
      elsif source == :worktrees
        names = value.map(&:name)
        raw.with(refs: value, **BY_NAME.to_h { [it, raw.public_send(it).slice(*names)] })
      elsif (field = REREAD[source])
        raw.with(field => raw.public_send(field).merge(value[:changed]).except(*value[:gone]))
      elsif REPLACE.include?(source)
        raw.with(source => value)
      else
        raise ArgumentError, "unknown source: #{key.inspect}"
      end
    end

    # The failures without the "<source>:<W>" keys of worktrees not in refs.
    def current(failures, refs)
      names = refs.map(&:name)
      failures.select { |key, _| (name = key.split(":", 2)[1]).nil? || names.include?(name) }
    end

    def publish(old, new)
      return if @subs.empty?

      before = old.worktrees.to_h { [it.name, it] }
      after = new.worktrees.to_h { [it.name, it] }
      (before.keys | after.keys).each do |name|
        was = before[name]
        wt = after[name]
        next if was == wt

        send_to(@subs, [:row, name])
        viewers = @subs.select { it.viewing == name }
        send_to(viewers, wt ? [:detail, name] : [:gone, name])
        send_to(@subs, [:notify, name]) if wt && asks?(wt) && agent_state(wt) != (was && agent_state(was))
      end
      send_to(@subs, [:header]) if header(old) != header(new)
    end

    def send_to(subs, event)
      event.freeze
      subs.each { it.queue << event }
    end

    def agent_state(wt) = wt.agent.is_a?(Agent) ? wt.agent.state : wt.agent
    def asks?(wt) = wt.agent.is_a?(Agent) && wt.agent.needs_input?
    def header(state) = [state.needs_input_count, state.raw.stale_units, state.raw.autostart]
  end
end
