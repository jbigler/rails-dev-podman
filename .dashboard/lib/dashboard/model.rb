# frozen_string_literal: true

module Dashboard
  # §5.1 value objects. A cell whose source failed holds UNKNOWN and renders `?`.
  UNKNOWN = :unknown

  Worktree    = Data.define(:name, :path, :base, :branch, :head_sha, :ahead, :behind, :upstream, :dirty_count, :env, :services, :pr, :stack, :agent)
  # state: :up | :starting | :stopped | :failed | :unknown. health: podman's health word, for "healthy" vs "running".
  Service     = Data.define(:label, :unit, :state, :port, :health)
  # state: :open | :merged | :closed; review: :approved | :changes | :review | :none
  # checks: { pass:, fail:, pending: } or nil (open PRs only); commits: Integer or nil, counted locally;
  # base_ref: the base branch name (open PRs only).
  Pr          = Data.define(:number, :title, :state, :draft, :review, :checks, :commits, :url, :base_ref)
  StackBranch = Data.define(:branch, :pr_number, :pr_state, :current, :merged, :needs_rebase)
  class Stack < Data.define(:trunk, :current_branch, :branches) # branches bottom → top
    def restack_needed? = branches.any?(&:needs_rebase)
    def open = branches.reject { it.merged && !it.current }
    def merged = branches.select { it.merged && !it.current }
    def current_index = branches.index(&:current)
    # 1-based position of HEAD's branch from the bottom.
    def position = current_index&.+(1)
  end
  # state: :permission | :question | :working | :done | :idle | :off
  Agent = Data.define(:state, :since, :message, :tool, :last_message) do
    def self.of(state, since: nil, message: nil, tool: nil, last_message: nil) = new(state:, since:, message:, tool:, last_message:)
    def needs_input? = %i[permission question].include?(state)
  end

  # Raw source results, keyed by worktree name where per worktree.
  # refs: [WorktreeRef]; git: name => GitInfo; env: name => [mtime, Hash] (.unit-env);
  # units: unit id => props; containers: name => Container; agent_files: name => [mtime, StatusFile];
  # prs: branch => Pr (open, with checks); pr_index: branch => Pr (all states, no checks);
  # commits: name => Integer; stacks: name => Stack | nil; stale_units: [String];
  # autostart: :enabled | :disabled | :unknown
  WorktreeRef = Data.define(:name, :path, :branch, :head_sha, :base)
  GitInfo     = Data.define(:ahead, :behind, :upstream, :dirty_count)
  Container   = Data.define(:name, :state, :health, :exit_code, :started_at) do
    def running? = state == "running"
  end
  # rtk: the hook's RTK savings Hash, or nil.
  StatusFile  = Data.define(:v, :state, :phase, :ts, :message, :tool, :last_message, :rtk)
  MiseTask    = Data.define(:name, :aliases, :description, :usage)

  Raw = Data.define(:refs, :git, :env, :units, :containers, :agent_files, :prs, :pr_index, :commits, :stacks, :stale_units, :autostart) do
    def self.empty
      new(refs: nil, git: {}, env: {}, units: {}, containers: {}, agent_files: {}, prs: {}, pr_index: {}, commits: {}, stacks: {},
          stale_units: [], autostart: UNKNOWN)
    end
  end

  # One action run. worktree: its name, nil for a workspace action; state: :running | :ok | :failed | :cancelled;
  # exit_status: the last command's (nil while running or when killed); lines: its output, the last
  # Runner::KEEP_LINES; created: the worktree a successful wt-create added. The Runner owns the
  # mutable one; the Hub holds frozen copies.
  Job = Struct.new(:id, :worktree, :label, :state, :exit_status, :started_at, :finished_at, :lines, :created, keyword_init: true) do
    def running? = state == :running
  end
end
