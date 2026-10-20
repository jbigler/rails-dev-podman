# frozen_string_literal: true

require "open3"

module Wt
  # Runs an external command without a shell, with a hard timeout. Every source
  # and action goes through here so nothing can hang the render loop.
  module Shell
    class Result < Data.define(:stdout, :stderr, :status, :timed_out)
      def ok? = !timed_out && status == 0
      # One line for a toast (see Shell.error_line), else the exit reason.
      def error_line
        return "timed out" if timed_out

        Shell.error_line(stderr) || "exit #{status}"
      end
    end

    # mise's own lines around a task: "[up] $ <command>" and "[up] ERROR task failed".
    MISE_NOISE = /\A\[[^\]]+\] (\$ |ERROR task failed)/

    # The line of stderr worth showing: the last "error: …" line (the convention every
    # .scripts/*.sh die() follows), else the last line that is not mise's wrapper.
    def self.error_line(stderr)
      lines = stderr.to_s.lines.map(&:strip).reject { it.empty? || it.match?(MISE_NOISE) }
      lines.reverse.find { it.match?(/\Aerror:/i) } || lines.last
    end

    # argv: Array of Strings. env: Hash merged into the environment.
    # Never raises for a failing or missing command: ENOENT becomes status 127.
    def self.capture(argv, chdir: nil, env: {}, timeout: 5, stdin: nil)
      opts = { pgroup: true }
      opts[:chdir] = chdir if chdir
      Open3.popen3(env, *argv, **opts) do |i, o, e, thr|
        i.write(stdin) if stdin
        i.close
        out_reader = Thread.new { o.read }
        err_reader = Thread.new { e.read }
        unless thr.join(timeout)
          kill_group(thr.pid)
          thr.join
          return Result.new(stdout: out_reader.value.to_s.freeze, stderr: err_reader.value.to_s.freeze, status: nil, timed_out: true)
        end
        Result.new(stdout: out_reader.value.freeze, stderr: err_reader.value.freeze, status: thr.value.exitstatus, timed_out: false)
      end
    rescue Errno::ENOENT, Errno::EACCES => e
      Result.new(stdout: "", stderr: e.message.freeze, status: 127, timed_out: false)
    end

    def self.kill_group(pid)
      Process.kill("TERM", -pid)
      sleep 0.2
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
  end
end
