# frozen_string_literal: true

require "socket"

module Wt
  module Acp
    # Long-running command (Refresh.start): every second, find `.run/<slug>/acp.sock`
    # of existing worktrees and keep one Connection per socket. A closed socket is
    # reported as :ended (file still there) or :disconnected (file gone), and is
    # retried while the file exists; a busy socket is retried less often.
    class Watch < Data.define(:config)
      include Rooibos::Command::Custom

      INTERVAL = 1.0
      RETRY = { ended: 2.0, busy: 5.0, refused: 2.0 }.freeze

      def rooibos_cancellation_grace_period = 0.5

      # slug → acp.sock path, for worktrees that still exist.
      def sockets
        Dir.glob(File.join(config.root, ".run", "*", "acp.sock")).each_with_object({}) do |path, h|
          slug = File.basename(File.dirname(path))
          h[slug] = path if File.socket?(path) && File.directory?(config.worktree_path(slug))
        end
      end

      def call(out, token)
        slots = {} # slug → { thread:, connection:, retry_at:, state: }
        until token.canceled?
          scan(out, token, slots)
          wait(token)
        end
      ensure
        slots&.each_value { it[:connection]&.close }
        slots&.each_value { it[:thread]&.join(0.5) }
      end

      def scan(out, token, slots)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        found = sockets
        slots.each do |slug, slot|
          next if slot[:thread]&.alive? || found.key?(slug) || slot[:state] == :disconnected

          out.put(Ractor.make_shareable(Msg::AcpConnection.new(slug:, state: :disconnected))) if slot[:state]
          slot[:state] = :disconnected
        end
        found.each do |slug, path|
          slot = (slots[slug] ||= {})
          next if slot[:thread]&.alive? || (slot[:retry_at] && now < slot[:retry_at])

          connect(out, token, slug, path, slot)
        end
      rescue StandardError => e
        warn "wt acp watch: #{e.class}: #{e.message}" if $DEBUG
      end

      private

      def connect(out, token, slug, path, slot)
        socket = UNIXSocket.new(path)
        connection = Connection.new(slug:, socket:, config:, out:)
        slot[:connection] = connection
        slot[:thread] = Thread.new do
          connection.run(token)
          finished(out, token, slug, path, slot, connection.outcome)
        end
      rescue SystemCallError, IOError
        slot[:retry_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RETRY[:refused]
      end

      def finished(out, token, slug, path, slot, outcome)
        return if token.canceled? || outcome == :canceled

        if outcome == :busy
          slot[:state] = :busy
          slot[:retry_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RETRY[:busy]
          return
        end
        state = File.exist?(path) ? :ended : :disconnected
        slot[:state] = state
        slot[:retry_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + RETRY[:ended]
        out.put(Ractor.make_shareable(Msg::AcpConnection.new(slug:, state:)))
      rescue StandardError
        nil
      end

      def wait(token)
        slept = 0.0
        while slept < INTERVAL && !token.canceled?
          sleep 0.1
          slept += 0.1
        end
      end
    end
  end
end
