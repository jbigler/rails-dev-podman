# frozen_string_literal: true

require "io/wait"

module Dashboard
  # Runs action specs as jobs, one thread each (spec "Actions"). Every child
  # starts in its own transient scope, so it outlives a dashboard restart. The
  # Hub gets a frozen copy of the job when it starts, at most every
  # PUBLISH_EVERY seconds while it prints, and when it ends.
  class Runner
    # The worktree, or for a workspace action the workspace, already has a running job.
    class Busy < Error; end

    SCOPE = %w[systemd-run --user --scope --collect --quiet --].freeze
    ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/
    KEEP_LINES = 5000
    # Bytes of one stored line; longer output (or none of it ending in a newline) is cut.
    MAX_LINE = 64 * 1024
    PUBLISH_EVERY = 0.1
    # The spec whose success adds a worktree (Job#created).
    CREATE = "wt-create"

    # A running job: the locks it holds (worktree names, :workspace), its current
    # child, a cancel request, output not yet published, and the flusher's wake-up.
    Entry = Struct.new(:job, :keys, :child, :cancelled, :dirty, :wake)

    # local: the LocalPoller, poked when a job ends; github: the GithubPoller,
    # hinted when a `github: true` job ends.
    def initialize(hub:, ws:, spawner: Spawn.new, github: nil, local: nil)
      @hub = hub
      @ws = ws
      @spawner = spawner
      @github = github
      @local = local
      @lock = Mutex.new
      @running = []
      @last_id = 0
    end

    # worktree: the Worktree it runs for (nil for a workspace action); input: a
    # prompted spec's answer; discard: wt-rm's "discard uncommitted changes".
    # → the Job as it starts. Raises Busy.
    def start(spec, worktree:, input: nil, discard: false)
      keys = [(:workspace if spec.scope == :workspace), worktree&.name].compact
      entry = @lock.synchronize do
        if (other = @running.find { it.keys.intersect?(keys) })
          raise Busy, "busy: #{[other.job.worktree, other.job.label].compact.join(': ')} is running"
        end

        job = Job.new(id: @last_id += 1, worktree: worktree&.name, label: spec.label, state: :running, started_at: Time.now, lines: [])
        Entry.new(job:, keys:, cancelled: false, dirty: false, wake: Thread::Queue.new).tap do
          @running << it
          publish(it)
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
        argv = [@ws.newterm, "--title", [wt&.name, spec.label].compact.join(": "), "--cwd", chdir, "--", *argv] if spec.mode == :terminal
        child = @lock.synchronize { entry.child = @spawner.spawn(SCOPE + argv, env:, chdir:) unless entry.cancelled }
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
    # edge scrubs to "?").
    def append(entry, text)
      cut = text.b.scan(/.{1,#{MAX_LINE}}/mn)
      cut = [""] if cut.empty?
      @lock.synchronize do
        lines = entry.job.lines
        cut.each { lines << it.force_encoding(Encoding::UTF_8).scrub("?").gsub(ANSI, "") }
        lines.shift(lines.size - KEEP_LINES) if lines.size > KEEP_LINES
        entry.dirty = true
      end
    end

    # Publishes new output at most every PUBLISH_EVERY seconds until the job ends.
    def flush(entry)
      @lock.synchronize { publish(entry) if entry.dirty } until entry.wake.pop(timeout: PUBLISH_EVERY)
    end

    # The pollers first, so the ended job is the last thing a page learns.
    def finish(entry, spec, status)
      @local&.poke
      @github&.hint(:action) if spec.github
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
      end
      entry.wake << :done
    end

    # Caller holds @lock, so a copy never overtakes a later one.
    def publish(entry)
      entry.dirty = false
      @hub.publish_job(copy(entry.job))
    end

    def copy(job) = job.dup.tap { it.lines = it.lines.dup.freeze }.freeze

    # Starts children for real: argv without a shell, in its own process group,
    # stdin from /dev/null, stdout and stderr on one pipe.
    class Spawn
      # → a Child; a command that cannot start is one that printed why and exited 127.
      def spawn(argv, env:, chdir:)
        reader, writer = IO.pipe
        pid = Process.spawn(env, [argv.first, argv.first], *argv.drop(1), pgroup: true, in: File::NULL, out: writer, err: writer, chdir:)
        Child.new(pid, reader)
      rescue SystemCallError => e
        reader&.close
        Unstarted.new("error: #{argv.first}: #{e.message}")
      ensure
        writer&.close
      end
    end

    # A started child process and the read end of its output pipe.
    class Child
      # Seconds the pipe may stay quiet after the child exited before reading stops.
      POLL = 0.2
      # Seconds between TERM and KILL.
      GRACE = 3

      def initialize(pid, io)
        @pid = pid
        @io = io
        @waiter = Process.detach(pid)
      end

      # Yields each output line (bytes, without the newline; MAX_LINE bytes at
      # most, so a long run without one is cut) until EOF, or until the child has
      # exited and a descendant keeps the pipe open but quiet.
      def each_line
        buffer = String.new(encoding: Encoding::BINARY)
        loop do
          if @io.wait_readable(POLL)
            chunk = @io.read_nonblock(65_536, exception: false)
            break if chunk.nil?
            next if chunk == :wait_readable

            buffer << chunk
            while (newline = buffer.index("\n"))
              yield buffer.slice!(0..newline).chomp
            end
            yield buffer.slice!(0, MAX_LINE) while buffer.bytesize >= MAX_LINE
          elsif !@waiter.alive?
            break
          end
        end
        yield buffer unless buffer.empty?
      ensure
        @io.close
      end

      # → the exit status, nil when a signal ended it.
      def wait = @waiter.value.exitstatus

      def kill
        signal("TERM")
        Thread.new do
          sleep GRACE
          signal("KILL")
        end
        nil
      end

      private

      def signal(name)
        Process.kill(name, -@pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    # A command that could not start: its reason as output, exit 127.
    Unstarted = Data.define(:message) do
      def each_line = yield(message)
      def wait = 127
      def kill = nil
    end
  end
end
