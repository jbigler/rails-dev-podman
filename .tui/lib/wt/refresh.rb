# frozen_string_literal: true

module Wt
  # Which sources run when. Every fetch is keyed ("source:slug"); a key still in
  # flight is skipped, so a slow podman never stacks up calls.
  #
  #   start  worktrees, status files, then everything once worktrees arrive; plus the
  #          long-running watchers: podman events (units refetch on change) and ACP sockets
  #   :fast  2 s   units (all worktrees), git status (visible rows), status files
  #   :slow  5 s   worktree list, stats + nvim (selected worktree only)
  #   :gh    60 s  PR + stack per worktree
  module Refresh
    INTERVALS = { fast: 2.0, slow: 5.0, gh: 60.0 }.freeze

    def self.start(model)
      tickers = INTERVALS.map { |kind, interval| Commands::Ticker.new(kind:, interval:) }
      watchers = [Commands::PodmanEvents.new(config: model.config), Acp::Watch.new(config: model.config)]
      schedule(model, [worktrees(model), status_files(model)], extra: tickers + watchers)
    end

    def self.on_tick(model, kind)
      case kind
      when :fast then schedule(model, [units(model), *git(model), status_files(model)])
      when :slow then schedule(model, [worktrees(model), *selected(model)])
      when :gh then schedule(model, gh(model))
      else [model, nil]
      end
    end

    # Everything for every worktree: first load, and after an action changed state.
    def self.all(model)
      schedule(model, [units(model), *git(model), *selected(model), *gh(model), status_files(model)])
    end

    # specs: [[key, source, *args], ...] → [model with inflight keys, batch command or nil]
    def self.schedule(model, specs, extra: [])
      specs = specs.compact.reject { model.inflight.include?(it[0]) }
      cmds = specs.map { |key, source, *args| Commands.fetch(model, key, source, *args) } + extra
      return [model, nil] if cmds.empty?

      [model.with(inflight: model.inflight + specs.map(&:first)), Rooibos::Command.batch(*cmds)]
    end

    def self.worktrees(m) = ["worktrees", Sources::Worktrees, m.config]
    def self.status_files(m) = ["status", Sources::StatusFiles, m.config]
    def self.units(m) = m.worktrees.empty? ? nil : ["units", Sources::Units, m.config, m.worktrees.map(&:slug)]
    def self.git(m) = m.visible_worktrees.map { ["git:#{it.slug}", Sources::GitStatus, m.config, it.slug] }

    def self.selected(m)
      wt = m.selected_worktree
      return [] unless wt

      [["stats:#{wt.slug}", Sources::Stats, m.config, wt.slug],
       (["nvim:#{wt.slug}", Sources::Nvim, m.config, wt.slug, wt.nvim_port] if wt.nvim_port)]
    end

    def self.gh(m)
      m.worktrees.flat_map do |wt|
        next [] unless wt.branch

        [["pr:#{wt.slug}", Sources::Pr, m.config, wt.slug, wt.branch], ["stack:#{wt.slug}", Sources::Stack, m.config, wt.slug]]
      end
    end
  end
end
