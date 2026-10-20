# frozen_string_literal: true

module Wt
  # Which sources run when. Every fetch is keyed ("source:slug"); a key still in
  # flight is skipped, so a slow podman never stacks up calls. An explicit request
  # (after an action, or `p`) for a key in flight is not dropped, though: it leaves
  # a "<key>+" marker in `inflight`, and the first schedule after that key reports
  # back — at the latest the next 2 s tick — fetches it again, so the result
  # reflects the action and not the state before it. (The marker lives in
  # `inflight` so Model needs no extra field; it never matches a real key.)
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

    # Everything for every worktree: first load, and after an action changed state
    # (the worktree list too, since `c` / `d` add and remove rows).
    def self.all(model)
      schedule(model, [worktrees(model), units(model), *git(model), *selected(model), *gh(model), status_files(model)],
               requeue: true)
    end

    REQUEUE = "+"

    # specs: [[key, source, *args], ...] → [model with inflight keys, batch command or nil]
    # requeue: keys already in flight are fetched again once they report back.
    def self.schedule(model, specs, extra: [], requeue: false)
      inflight = model.inflight
      markers = inflight.select { it.end_with?(REQUEUE) }
      due = markers.reject { inflight.include?(it.delete_suffix(REQUEUE)) }
      specs = (specs.compact + due.filter_map { spec_for(model, it.delete_suffix(REQUEUE)) }).uniq(&:first)
      busy, run = specs.partition { inflight.include?(it[0]) }
      waiting = requeue ? busy.map { -"#{it[0]}#{REQUEUE}" } : []
      cmds = run.map { |key, source, *args| Commands.fetch(model, key, source, *args) } + extra
      inflight = ((inflight - due) + run.map(&:first) + waiting).uniq
      model = model.with(inflight: Ractor.make_shareable(inflight)) unless inflight == model.inflight
      [model, cmds.empty? ? nil : Rooibos::Command.batch(*cmds)]
    end

    # The spec for a fetch key, rebuilt from the current model (nil once its
    # worktree is gone or no longer qualifies).
    def self.spec_for(m, key)
      [worktrees(m), status_files(m), units(m), *m.worktrees.flat_map { [git_for(m, it), *per_worktree(m, it), *gh_for(m, it)] }]
        .compact.find { it[0] == key }
    end

    def self.worktrees(m) = ["worktrees", Sources::Worktrees, m.config]
    def self.status_files(m) = ["status", Sources::StatusFiles, m.config]
    def self.units(m) = m.worktrees.empty? ? nil : ["units", Sources::Units, m.config, m.worktrees.map(&:slug)]
    def self.git(m) = m.visible_worktrees.map { git_for(m, it) }

    def self.selected(m)
      wt = m.selected_worktree
      wt ? per_worktree(m, wt) : []
    end

    def self.git_for(m, wt) = ["git:#{wt.slug}", Sources::GitStatus, m.config, wt.slug]

    # Stats + nvim: polled for the selected worktree only.
    def self.per_worktree(m, wt)
      [["stats:#{wt.slug}", Sources::Stats, m.config, wt.slug],
       (["nvim:#{wt.slug}", Sources::Nvim, m.config, wt.slug, wt.nvim_port] if wt.nvim_port)]
    end

    def self.gh(m) = m.worktrees.flat_map { gh_for(m, it) }
    def self.gh_for(m, wt) = wt.branch ? [pr(m, wt), ["stack:#{wt.slug}", Sources::Stack, m.config, wt.slug]] : []
    def self.pr(m, wt) = (["pr:#{wt.slug}", Sources::Pr, m.config, wt.slug, wt.branch] if wt.branch)
  end
end
