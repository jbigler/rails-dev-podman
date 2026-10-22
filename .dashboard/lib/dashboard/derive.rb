# frozen_string_literal: true

module Dashboard
  # Raw source results → [Worktree] for the views. Rerun after every source result.
  # failed: the Hub's failure keys — "units", "prs", … or "<source>:<W>" for one worktree.
  module Derive
    GIT_UNKNOWN = GitInfo.new(ahead: UNKNOWN, behind: UNKNOWN, upstream: UNKNOWN, dirty_count: UNKNOWN)

    def self.worktrees(ws, raw, failed)
      refs = raw.refs || []
      units = failed.key?("units") ? UNKNOWN : raw.units
      containers = failed.key?("containers") ? UNKNOWN : raw.containers
      sorted = refs.reject(&:base).sort_by(&:name) + refs.select(&:base)
      sorted.map do |ref|
        git = failed.key?("git:#{ref.name}") ? GIT_UNKNOWN : raw.git[ref.name]
        env = raw.env[ref.name]&.last || {}
        Worktree.new(
          name: ref.name, path: ref.path, base: ref.base, branch: ref.branch, head_sha: ref.head_sha,
          ahead: git&.ahead, behind: git&.behind, upstream: git&.upstream, dirty_count: git&.dirty_count, env:,
          services: Services.for(ws, ref.name, env, units, containers),
          pr: pr(ref, raw, failed),
          stack: failed.key?("stacks:#{ref.name}") ? UNKNOWN : raw.stacks[ref.name],
          agent: AgentStatus.derive(containers == UNKNOWN ? UNKNOWN : containers[ws.container(ref.name, "claude")], raw.agent_files[ref.name]&.last)
        )
      end
    end

    # The open list (with checks) first, else the all-states index; the commit
    # count is computed locally per worktree.
    def self.pr(ref, raw, failed)
      return nil unless ref.branch
      return UNKNOWN if failed.key?("prs")

      pr = raw.prs[ref.branch] || raw.pr_index[ref.branch]
      pr&.with(commits: failed.key?("commits:#{ref.name}") ? UNKNOWN : raw.commits[ref.name])
    end
    private_class_method :pr
  end
end
