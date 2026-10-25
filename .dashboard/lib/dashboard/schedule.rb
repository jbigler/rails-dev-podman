# frozen_string_literal: true

module Dashboard
  # When each source is read. Pure: the caller passes the time, so tests drive
  # it with plain Time values. Not thread-safe: LocalPoller's thread alone uses
  # the local half, GithubPoller uses the GitHub half under its own lock.
  class Schedule
    LOCAL = { worktrees: 5, git: 3, units: 3, containers: 3, agent_files: 1, unit_env: 1, stale_units: 60, autostart: 60 }.freeze
    HOT = 60
    COOL = 300
    COALESCE = 10 # a focus hint this soon after the last refresh is dropped

    # Every local source is due at `now`.
    def initialize(now)
      @local_at = LOCAL.transform_values { now }
      @running = false # a GitHub refresh runs, or a :run verdict is about to start one
      @queued = false  # an action hint arrived while it ran
      @finished_at = nil
    end

    # The local sources due at `now`, each rescheduled one interval on.
    def local_due(now) = reschedule(LOCAL.keys.select { now >= @local_at[it] }, now)

    # Every local source, at once (after an action); the intervals restart from `now`.
    def local_all(now) = reschedule(LOCAL.keys, now)

    # The GitHub timer. Never with no page open; every HOT seconds while some
    # open PR has checks pending or a viewed worktree has an open PR, else COOL.
    def github_due?(now, subscribers:, hot:)
      return false if subscribers.zero? || @running
      return true unless @finished_at

      now - @finished_at >= (hot ? HOT : COOL)
    end

    # kind: :focus (a page connected or regained focus) or :action (an action
    # that touches GitHub finished). → :run (start a refresh now), :drop, or
    # :queued (a refresh runs; it runs again when it ends).
    def hint(now, kind)
      if @running
        return :drop if kind == :focus

        @queued = true
        return :queued
      end
      return :drop if kind == :focus && @finished_at && now - @finished_at < COALESCE

      @running = true
      :run
    end

    def github_started(_now)
      @running = true
    end

    # → true when an action hint was queued: run again now (still running).
    def github_finished(now)
      @finished_at = now
      again = @queued
      @queued = false
      @running = again
    end

    private

    def reschedule(keys, now)
      keys.each { @local_at[it] = now + LOCAL[it] }
      keys
    end
  end
end
