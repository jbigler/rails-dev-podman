# frozen_string_literal: true

module Dashboard
  class Runner
    # Starts children for real: argv without a shell, in its own process group,
    # with ChildEnv plus env, stdin from /dev/null, stdout and stderr appended
    # to the job's log, <dir>/<job id>.log (0600). A file, not a pipe: a child
    # that writes after the dashboard stopped would die of SIGPIPE. Logs left by
    # an earlier run are deleted (job ids start over).
    class Spawn
      # Bytes a log may reach before its reader empties it (Child#trim): logs
      # live on $XDG_RUNTIME_DIR, a small tmpfs that also holds the podman socket.
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
        pid = Process.spawn(ChildEnv.with(env), [argv.first, argv.first], *argv.drop(1),
                            pgroup: true, unsetenv_others: true, in: File::NULL, out:, err: out, chdir:)
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
      # Seconds between looks at a log with nothing new in it.
      POLL = 0.1
      # Seconds between TERM and KILL.
      GRACE = 3
      # Bytes asked of the log per read.
      READ = 65_536

      # io: the log, open read-write (the reader truncates it); limit: Spawn's log_limit.
      def initialize(pid, io, limit)
        @pid = pid
        @io = io
        @limit = limit
        @waiter = Process.detach(pid)
      end

      # Yields each output line (bytes, without the newline; MAX_LINE bytes at
      # most, so a long run without one is cut) while the child runs, then what
      # it left in the log. Leaving early (the dashboard stopping) only stops
      # the reading; the child goes on writing to the file.
      def each_line
        buffer = String.new(encoding: Encoding::BINARY)
        loop do
          exited = !@waiter.alive?
          chunk = @io.read(READ)
          if chunk
            buffer << chunk
            while (newline = buffer.index("\n"))
              yield buffer.slice!(0..newline).chomp
            end
            yield buffer.slice!(0, MAX_LINE) while buffer.bytesize >= MAX_LINE
          end
          trim(caught_up: chunk.nil? || chunk.bytesize < READ, exited:)
          next if chunk
          break if exited

          sleep POLL
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

      # The child appends (O_APPEND), so emptying the log in place is safe: its
      # next write lands at 0, where reading goes on. Once read past the limit
      # and caught up, nothing is lost but a write landing between the last read
      # and the truncate. A reader that stays behind a live child truncates at
      # twice the limit anyway, dropping what it had not read yet.
      def trim(caught_up:, exited:)
        read = @io.pos
        return unless read >= @limit && (caught_up || (read >= 2 * @limit && !exited))

        @io.truncate(0)
        @io.seek(0)
      end

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
