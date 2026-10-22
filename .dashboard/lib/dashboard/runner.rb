# frozen_string_literal: true

module Dashboard
  # Runs action specs as jobs, one thread each (spec "Actions"). Every child
  # starts in its own transient scope and writes to a log file rather than a
  # pipe (Runner::Spawn), so it outlives a dashboard stop or restart. The Hub
  # gets a frozen copy of the job when it starts, at most every PUBLISH_EVERY
  # seconds while it prints, and when it ends.
  class Runner
    # The worktree, or for a workspace action the workspace, already has a running job.
    class Busy < Error; end

    SCOPE = %w[systemd-run --user --scope --collect --quiet --].freeze
    ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/
    KEEP_LINES = 5000
    # Bytes of output a job keeps; the oldest lines go first.
    KEEP_BYTES = 4 * 1024 * 1024
    # Bytes of one stored line; longer output (or none of it ending in a newline) is cut.
    MAX_LINE = 64 * 1024
    PUBLISH_EVERY = 0.1
    # The spec whose success adds a worktree (Job#created).
    CREATE = "wt-create"

    # A running job: the locks it holds (worktree names, :workspace), its current
    # child, a cancel request, output not yet published, the flusher's wake-up,
    # and the bytes its lines hold.
    Entry = Struct.new(:job, :keys, :child, :cancelled, :dirty, :wake, :bytes)

    # local: the LocalPoller, poked when a job ends; github: the GithubPoller,
    # hinted when a `github: true` job ends. The default spawner logs to the
    # workspace's PrivateDir.
    def initialize(hub:, ws:, spawner: Spawn.new(File.join(PrivateDir.for(ws.prefix), "jobs")), github: nil, local: nil)
      @hub = hub
      @ws = ws
      @spawner = spawner
      @github = github
      @local = local
      @lock = Mutex.new
      @running = []
      @last_id = 0
      @logged = []
    end

    # worktree: the Worktree it runs for (nil for a workspace action); input: a
    # prompted spec's answer or the chosen one of its choices; discard: wt-rm's "discard uncommitted changes".
    # → the Job as it starts. Raises Busy.
    def start(spec, worktree:, input: nil, discard: false)
      keys = [(:workspace if spec.scope == :workspace), worktree&.name].compact
      entry = @lock.synchronize do
        if (other = @running.find { it.keys.intersect?(keys) })
          raise Busy, "busy: #{[other.job.worktree, other.job.title].compact.join(': ')} is running"
        end

        job = Job.new(id: @last_id += 1, worktree: worktree&.name, action: spec.id, label: spec.label, input:, state: :running,
                      started_at: Time.now, lines: [])
        Entry.new(job:, keys:, cancelled: false, dirty: false, wake: Thread::Queue.new, bytes: 0).tap do
          @running << it
          @logged << job.id
          publish(it)
          forget_dropped
        end
      end
      started = @lock.synchronize { copy(entry.job) }
      Thread.new { run(entry, spec, worktree, input, discard) }.name = "job-#{entry.job.id}"
      started
    end

    # Ends a running job: TERM, then KILL, to its child's process group; the
    # commands after it never start. → false when no such job is running.
    def cancel(id)
      child = @lock.synchronize do
        entry = @running.find { it.job.id == id }
        return false unless entry

        entry.cancelled = true
        entry.child
      end
      child&.kill
      true
    end

    # The running and recent jobs, as the Hub holds them (newest last).
    def jobs = @hub.snapshot.jobs

    private

    def run(entry, spec, wt, input, discard)
      Thread.new { flush(entry) }.name = "job-#{entry.job.id}-flush"
      status = begin
        execute(entry, spec, wt, input, discard)
      rescue StandardError => e
        append(entry, "error: #{e.message}")
        nil
      end
    ensure
      finish(entry, spec, status)
    end

    # Runs the spec's commands up to the first failure. → the last exit status
    # (nil when killed or cancelled before a command started).
    def execute(entry, spec, wt, input, discard)
      before = refs if spec.id == CREATE
      env = SessionEnv.current.merge(spec.environment(discard))
      chdir = spec.scope == :workspace ? @ws.root : wt.path
      status = 0
      spec.argv.(@ws, wt, input).each do |argv|
        argv = [@ws.newterm, "--title", [wt&.name, entry.job.title].compact.join(": "), "--cwd", chdir, "--", *argv] if spec.mode == :terminal
        child = @lock.synchronize { entry.child = @spawner.spawn(SCOPE + argv, env:, chdir:, job: entry.job.id) unless entry.cancelled }
        return nil unless child

        child.each_line { append(entry, it) }
        status = child.wait
        break unless status == 0
      end
      append(entry, "opened #{spec.label}") if spec.mode == :terminal && status == 0
      created(entry, before) if before && status == 0
      status
    end

    # The worktree names now, nil when they cannot be read.
    def refs
      Sources::Worktrees.fetch(@ws).map(&:name)
    rescue Sources::Failed
      nil
    end

    def created(entry, before)
      name = refs&.-(before)&.first
      @lock.synchronize { entry.job.created = name }
    end

    # Stored as lines of at most MAX_LINE bytes (a multibyte character cut at the
    # edge scrubs to "?"), KEEP_LINES and KEEP_BYTES at most.
    def append(entry, text)
      cut = text.b.scan(/.{1,#{MAX_LINE}}/mn)
      cut = [+""] if cut.empty? # an empty line; unfrozen, force_encoding below changes it in place
      @lock.synchronize do
        lines = entry.job.lines
        cut.each do
          line = it.force_encoding(Encoding::UTF_8).scrub("?").gsub(ANSI, "")
          lines << line
          entry.bytes += line.bytesize
        end
        entry.bytes -= lines.shift.bytesize while lines.size > KEEP_LINES || entry.bytes > KEEP_BYTES
        entry.dirty = true
      end
    end

    # Publishes new output at most every PUBLISH_EVERY seconds until the job ends.
    def flush(entry)
      @lock.synchronize { publish(entry) if entry.dirty } until entry.wake.pop(timeout: PUBLISH_EVERY)
    end

    # The pollers first, so the ended job is the last thing a page learns; the
    # job leaves @running even when they raise, or its locks would stay held.
    def finish(entry, spec, status)
      @local&.poke
      @github&.hint(:action) if spec.github
    ensure
      @lock.synchronize do
        job = entry.job
        job.exit_status = status
        job.state = if entry.cancelled then :cancelled
                    elsif status == 0 then :ok
                    else :failed
                    end
        job.finished_at = Time.now
        @running.delete(entry)
        publish(entry)
        forget_dropped
      end
      entry.wake << :done
    end

    # Deletes the logs of jobs the Hub no longer keeps. Caller holds @lock.
    def forget_dropped
      kept = @hub.snapshot.jobs.map(&:id)
      (@logged - kept).each do |id|
        @spawner.forget(id)
        @logged.delete(id)
      end
    end

    # Caller holds @lock, so a copy never overtakes a later one.
    def publish(entry)
      entry.dirty = false
      @hub.publish_job(copy(entry.job))
    end

    def copy(job) = job.dup.tap { it.lines = it.lines.dup.freeze }.freeze
  end
end
