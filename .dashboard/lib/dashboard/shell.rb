# frozen_string_literal: true

module Dashboard
  # The only place the dashboard spawns a read. Tests swap `Shell.backend` for
  # a fake that replays fixtures.
  module Shell
    TIMEOUT = 5
    GH_TIMEOUT = 15

    class Result < Data.define(:stdout, :stderr, :status, :timed_out)
      def self.ok(stdout = "") = new(stdout: stdout, stderr: "", status: 0, timed_out: false)
      def self.fail(stderr, status: 1) = new(stdout: "", stderr: stderr, status:, timed_out: false)

      def ok? = !timed_out && status == 0
      # The command could not run at all (missing binary) or hung.
      def broken? = timed_out || status == 127

      # mise's own wrapper lines around a failing task, never the cause.
      MISE_NOISE = /\A(\[[^\]]+\] (\$ |ERROR task failed)|mise ERROR (Version:|Run with --verbose))/

      # One line for a toast: the last "error: …" line (the .scripts/*.sh die()
      # convention), else the last line that is not mise's boilerplate.
      def error_line
        return "timed out" if timed_out

        lines = stderr.to_s.lines.map(&:strip).reject { it.empty? || it.match?(MISE_NOISE) }
        line = lines.reverse.find { it.match?(/\Aerror:/i) } || lines.last || "exit #{status}"
        line.delete_prefix("mise ERROR ")
      end
    end

    # Runs commands for real.
    class Real
      # argv without a shell, in its own process group so a timeout kills the
      # whole tree. A missing binary is status 127, never an exception.
      def run(argv, chdir: nil, timeout: TIMEOUT, env: {})
        opts = { pgroup: true, in: File::NULL }
        opts[:chdir] = chdir if chdir
        Open3.popen3(env, *argv, **opts) do |i, o, e, thr|
          i.close
          out = Thread.new { o.read }
          err = Thread.new { e.read }
          unless thr.join(timeout)
            kill_group(thr.pid)
            thr.join
            return Result.new(stdout: out.value.to_s, stderr: err.value.to_s, status: nil, timed_out: true)
          end
          Result.new(stdout: out.value, stderr: err.value, status: thr.value.exitstatus, timed_out: false)
        end
      rescue SystemCallError => e
        Result.new(stdout: "", stderr: e.message, status: 127, timed_out: false)
      end

      private

      def kill_group(pid)
        Process.kill("TERM", -pid)
        sleep 0.2
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
    end

    class << self
      attr_writer :backend

      def backend = @backend ||= Real.new
      def run(argv, chdir: nil, timeout: TIMEOUT, env: {}) = backend.run(argv, chdir:, timeout:, env:)
    end
  end
end
