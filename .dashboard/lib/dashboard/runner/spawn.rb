# frozen_string_literal: true

module Dashboard
  class Runner
    # Starts children for real: argv without a shell, in its own process group,
    # with ChildEnv plus env, stdin from /dev/null, stdout and stderr appended
    # to the job's log, <dir>/<job id>.log (0600). A file, not a pipe: a child
    # that writes after the dashboard stopped would die of SIGPIPE. Logs left by
    # an earlier run are deleted (job ids start over).
    class Spawn
      # The log size LogTail keeps a log near: logs live on $XDG_RUNTIME_DIR,
      # a small tmpfs that also holds the podman socket.
      LOG_LIMIT = 8 * 1024 * 1024

      # dir: a private directory (made 0700 if missing).
      def initialize(dir, log_limit: LOG_LIMIT)
        @dir = PrivateDir.make(dir)
        @log_limit = log_limit
        Dir.glob(File.join(@dir, "*.log")).each { File.unlink(it) }
      end

      # job: the job id; its commands share one log. → a Child; a command that
      # cannot start is one that printed why and exited 127.
      def spawn(argv, env:, chdir:, job:)
        path = log(job)
        out = File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::NOFOLLOW, 0o600)
        reader = File.open(path, File::RDWR | File::NOFOLLOW)
        reader.seek(0, IO::SEEK_END)
        # close_others: Falcon clears close-on-exec on its listening socket, and
        # a child in its own scope outlives the dashboard; one that kept the
        # socket held the port, failing the next start with EADDRINUSE.
        pid = Process.spawn(ChildEnv.with(env), [argv.first, argv.first], *argv.drop(1),
                            pgroup: true, unsetenv_others: true, close_others: true,
                            in: File::NULL, out:, err: out, chdir:)
        Child.new(pid, reader, @log_limit)
      rescue SystemCallError => e
        reader&.close
        Unstarted.new("error: #{argv.first}: #{e.message}")
      ensure
        out&.close
      end

      # Deletes a job's log (the job left the Hub's retention).
      def forget(job)
        File.unlink(log(job))
      rescue Errno::ENOENT
        nil
      end

      private

      def log(job) = File.join(@dir, "#{Integer(job)}.log")
    end

    # A started child process and its log, read from where it started.
    class Child
      # Seconds between TERM and KILL.
      GRACE = 3

      # io: the log, open read-write (the reader truncates it); limit: Spawn's log_limit.
      def initialize(pid, io, limit)
        @pid = pid
        @waiter = Process.detach(pid)
        @tail = LogTail.new(io, limit, -> { @waiter.alive? })
      end

      # Yields each output line (LogTail#each_line) while the child runs, then
      # what it left in the log; partial: LogTail's unfinished-line callback.
      # Leaving early (the dashboard stopping) only stops the reading; the
      # child goes on writing to the file.
      def each_line(partial: nil, &) = @tail.each_line(partial:, &)

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
      def each_line(partial: nil) = yield(message)
      def wait = 127
      def kill = nil
    end
  end
end
