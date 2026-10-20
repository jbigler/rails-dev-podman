# frozen_string_literal: true

module Wt
  module Commands
    # Long-running watcher started by Refresh.start: follows
    # `podman events --format json --filter type=container` and, when one of this
    # workspace's containers (`<prefix>-…`) changes, puts Msg::UnitsDirty so the
    # services refetch at once instead of on the next 2 s tick — at most every 0.5 s.
    # A missing podman or a stream that dies is retried after BACKOFF, until cancelled.
    class PodmanEvents < Data.define(:config)
      include Rooibos::Command::Custom

      COMMAND = %w[podman events --format json --filter type=container].freeze
      DEBOUNCE = 0.5
      BACKOFF = 30.0
      DIRTY = Ractor.make_shareable(Msg::UnitsDirty.new)
      # Lifecycle changes the pod panel shows. health_status fires on every check
      # (every 5 s per container), so it only counts when the result changed.
      STATUSES = %w[create init start restart stop died kill remove pause unpause].freeze

      # Leading and trailing edge: the first change is reported at once, later ones
      # within `interval` collapse into one report when the interval ends.
      class Debounce
        def initialize(interval)
          @interval = interval
          @last = -Float::INFINITY
          @pending = false
        end

        def hit = @pending = true

        def due?(now)
          return false unless @pending && now - @last >= @interval

          @pending = false
          @last = now
          true
        end
      end

      def call(out, token)
        until token.canceled?
          watch(out, token)
          Follow.pause(token, BACKOFF)
        end
      end

      private

      def watch(out, token)
        health = {}
        debounce = Debounce.new(DEBOUNCE)
        Follow.run(COMMAND, token) do |line|
          debounce.hit if line && change?(line, health)
          out.put(DIRTY) if debounce.due?(Process.clock_gettime(Process::CLOCK_MONOTONIC))
        end
      end

      # Does this event line change what the pod panel shows? health: name → last health
      # status seen, so repeated health_status events with the same result are dropped.
      def change?(line, health)
        event = JSON.parse(line)
        name = event["Name"].to_s
        return false unless event["Type"] == "container" && name.start_with?("#{config.prefix}-")

        status = event["Status"]
        return STATUSES.include?(status) unless status == "health_status"

        changed = health[name] != event["health_status"]
        health[name] = event["health_status"]
        changed
      rescue JSON::ParserError
        false
      end
    end
  end
end
