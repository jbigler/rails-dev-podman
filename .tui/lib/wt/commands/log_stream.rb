# frozen_string_literal: true

require "open3"

module Wt
  module Commands
    # Runs a never-ending reader (`podman events`, `podman logs -f`, `journalctl -f`)
    # in its own process group, yielding each stdout+stderr line, and nil every
    # ~0.1 s so the caller can flush on time. Returns the exit status when the
    # program ends, :canceled once the token fires (the group is killed), and
    # :missing when the program cannot start.
    module Follow
      POLL = 0.1

      def self.run(argv, token, chdir: nil)
        opts = { pgroup: true }
        opts[:chdir] = chdir if chdir
        Open3.popen2e(*argv, **opts) do |stdin, out, thr|
          stdin.close
          buf = +""
          until token.canceled?
            if IO.select([out], nil, nil, POLL)
              chunk = out.read_nonblock(65_536, exception: false)
              break if chunk.nil?

              buf << chunk unless chunk == :wait_readable
              while (i = buf.index("\n"))
                yield line(buf.slice!(0..i))
              end
            end
            yield nil
          end
          next :canceled if token.canceled?

          yield line(buf) unless buf.empty?
          thr.value.exitstatus
        ensure
          # Canceled, the thread killed (wt quitting) or yield raised: popen2e's own
          # ensure would join a child that never ends, so kill its group first.
          Shell.kill_group(thr.pid) if thr&.alive? || token.canceled?
        end
      rescue Errno::ENOENT, Errno::EACCES
        :missing
      end

      def self.line(raw) = raw.chomp.force_encoding(Encoding::UTF_8).scrub.freeze

      # Sleeps `seconds` in POLL steps; false when the token fired meanwhile.
      def self.pause(token, seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        sleep POLL while !token.canceled? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        !token.canceled?
      end
    end

    # Follows one service's output for the full-tier log panel, as `mise run logs`
    # (cmd_logs in .scripts/podman-wt.sh) would: the container's output via
    # `podman logs -f`, or the unit journal for the oneshots whose container is gone
    # (deps, rustfs-init). Emits Msg::LogLines batches at most every 100 ms.
    #
    # The container stops and comes back (restart recreates it), so a follow that
    # ends is retried, picking up from when it ended; while there is no container
    # one status line says so.
    class LogStream < Data.define(:config, :slug, :svc)
      include Rooibos::Command::Custom

      JOURNAL = %w[deps rustfs-init net-network].freeze
      TAIL = 200
      FLUSH = 0.1
      RETRY = 2.0
      MISSING_RETRY = 30.0

      def container = config.container_name(svc, slug)
      def unit = config.unit_name(svc, slug)

      def call(out, token)
        since = nil
        notice = nil
        until token.canceled?
          problem = availability
          unless problem
            result = follow(out, token, argv(since))
            return if result == :canceled

            problem = "#{argv.first} not found" if result == :missing
            since = Time.now
          end
          # Each problem is said once, until following works again.
          out.put(Ractor.make_shareable(Msg::LogLines.new(slug:, svc:, lines: ["── #{problem}"]))) if problem && problem != notice
          notice = problem
          Follow.pause(token, problem&.end_with?("not found") ? MISSING_RETRY : RETRY)
        end
      end

      def argv(since = nil)
        return ["journalctl", "--user", "-f", "-u", unit, "-o", "cat", "-n", TAIL.to_s] if JOURNAL.include?(svc)
        return ["podman", "logs", "-f", "--since", since.utc.iso8601, container] if since

        ["podman", "logs", "-f", "--tail", TAIL.to_s, container]
      end

      private

      # nil when there is something to follow, else a status line saying why not.
      def availability
        return nil if JOURNAL.include?(svc)

        r = Shell.capture(["podman", "container", "exists", container], timeout: config.timeout)
        if r.status == 127 then "podman not found"
        elsif r.ok? then nil
        else "no container #{container} (yet); see mise run status"
        end
      end

      def follow(out, token, argv)
        pending = []
        flushed = 0.0
        flush = lambda do
          out.put(Ractor.make_shareable(Msg::LogLines.new(slug:, svc:, lines: pending))) unless pending.empty?
          pending = []
          flushed = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        result = Follow.run(argv, token) do |line|
          pending << line if line
          flush.call if Process.clock_gettime(Process::CLOCK_MONOTONIC) - flushed >= FLUSH
        end
        flush.call unless result == :canceled
        result
      end
    end
  end
end
