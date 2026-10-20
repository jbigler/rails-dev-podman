# frozen_string_literal: true

module Wt
  # The single immutable application state. Every Hash is keyed by worktree slug.
  # Values are replaced wholesale by messages (see messages/*.rb), never mutated.
  class Model < Data.define(
    :config,     # Config
    :worktrees,  # [Worktree], base first, then `git worktree list` order
    :git,        # slug => GitStatus
    :services,   # slug => [Service] in Service::NAMES order
    :stats,      # slug => { container_name => Stats } (selected worktree only)
    :prs,        # slug => PrStatus | :none (no PR for the branch)
    :stacks,     # slug => Stack
    :agents,     # slug => AgentStatus (status file)
    :sessions,   # slug => AgentSession (ACP)
    :nvim,       # slug => NvimStatus
    :log_lines,  # [String] tail of the followed service log (full tier)
    :log_stream, # the running Commands::LogStream (kept so it can be cancelled), or nil
    :stale_units, # installed unit files that differ from .container-config/quadlet/ (nil = not checked yet)
    :busy,       # slug (nil = the workspace) => Busy, a mise action still running there
    :failures,   # "source:key" => error text; views draw a dimmed ? for that cell
    :inflight,   # [String] fetch keys whose command has not reported back yet
    :gh_at,      # Time of the last successful gh call (top bar "gh ✓ 40s ago")
    :now,        # Time, advanced by Tick so views stay pure
    :ui          # Ui
  )
    def initialize(
      config:, worktrees: [], git: {}, services: {}, stats: {}, prs: {}, stacks: {}, agents: {},
      sessions: {}, nvim: {}, log_lines: [], log_stream: nil, stale_units: nil, busy: {}, failures: {}, inflight: [], gh_at: nil,
      now: Time.now, ui: Ui.new
    )
      super
    end

    def selected_worktree = worktrees.find { it.slug == ui.selected } || worktrees.first
    def worktree(slug) = worktrees.find { it.slug == slug }
    # A per-worktree source fails as "source:slug"; units and status files are one call
    # for every worktree, keyed by the bare source name, so that failure covers every slug.
    def failed?(source, key) = failures.key?("#{source}:#{key}") || failures.key?(source.to_s)

    # Visible worktree list after the `/` filter (name, branch or PR number).
    def visible_worktrees
      return worktrees if ui.filter.empty?

      needle = ui.filter.downcase
      worktrees.select do |wt|
        pr = prs[wt.slug]
        [wt.slug, wt.branch.to_s, (pr.is_a?(PrStatus) ? "##{pr.number}" : "")].any? { it.downcase.include?(needle) }
      end
    end

    # Replace one slug's entry in a slug-keyed hash field.
    def put(field, slug, value) = with(field => public_send(field).merge(slug => value))

    def toast(text, level: :info)
      id = ui.next_toast_id
      [with(ui: ui.with(toasts: [*ui.toasts, Toast.new(id:, text:, level:)].last(3), next_toast_id: id + 1)), id]
    end

    # toast + the command that expires it: return this straight from an action.
    def notify(text, level: :info)
      model, id = toast(text, level:)
      [model, Commands.expire_toast(id)]
    end

    # The worktree the current screen is about: chat → its slug, agents → the
    # selected card in urgency order, otherwise the selected list row.
    def focus_slug
      case ui.screen
      when :chat then ui.chat_slug || ui.selected
      when :agents then agents_by_urgency[ui.agents_index] || ui.selected
      else ui.selected
      end
    end

    def permission_for(slug) = slug && sessions[slug]&.permission

    # One display state per worktree's agent, ACP session first, status file second:
    #   :permission ◆ | :failed ✗ | :running ● | :starting ◐ | :done · | :offline ○ | nil (no agent at all)
    def agent_state(slug)
      if (s = sessions[slug]) && s.connection != :disconnected
        return :permission if s.permission
        return :failed if s.error || s.tool_calls.last&.status == :failed
        return :running if s.running
        return :starting if s.connection == :connecting
        return s.connection == :ended ? :offline : :done
      end
      case agents[slug]&.state
      when :permission then :permission
      when :failed then :failed
      when :working then :running
      when :waiting then :done
      when :offline then :offline
      end
    end

    URGENCY = %i[permission failed running starting done offline].freeze

    # Slugs that have an agent, permission → failed → running → starting → done →
    # offline, then worktree list order. ^1–^9 and the Agents screen follow this order.
    def agents_by_urgency
      worktrees.each_with_index
               .filter_map { |wt, i| (st = agent_state(wt.slug)) && [URGENCY.index(st), i, wt.slug] }
               .sort.map(&:last)
    end
  end
end
