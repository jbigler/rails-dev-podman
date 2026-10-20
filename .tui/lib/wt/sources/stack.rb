# frozen_string_literal: true

module Wt
  module Sources
    # The gh stack a worktree's HEAD sits in, from `gh stack view --json`
    # (github/gh-stack ≥ 0.2; the spec's risk row prefers its JSON flag over the
    # text view, and over re-deriving the chain from each PR's baseRefName).
    # gh-stack keeps one catalog per clone (<common-dir>/gh-stack), so every
    # worktree sees the same stacks; the view also reports needsRebase per branch
    # (its base is no longer an ancestor) and each branch's PR number.
    #
    # Review, draft and CI per entry come from one `gh pr view <number>` per PR,
    # run in parallel; one that fails leaves that entry's columns blank.
    module Stack
      VIEW = %w[gh stack view --json].freeze

      # gh-stack exit codes that mean "HEAD is in no single stack": 2 not part of a
      # stack, 6 in several (the trunk branch belongs to every stack).
      NOT_IN_STACK = [2, 6].freeze

      def self.fetch(config, slug)
        dir = config.worktree_path(slug)
        r = Shell.capture(VIEW, chdir: dir, env: Pr::GH_ENV, timeout: config.timeout, stdin: "")
        stack = if r.ok? then enrich(parse(r.stdout), dir, config.timeout)
                elsif !r.timed_out && NOT_IN_STACK.include?(r.status) then Wt::Stack.new
                else raise Error, "gh stack view: #{r.error_line}"
                end
        Msg::StackLoaded.new(slug:, stack:)
      end

      # Entries trunk-up (gh-stack lists bottom first). Merged branches have left the
      # stack and are dropped — unless HEAD is still on one, so its position shows.
      def self.parse(json)
        data = JSON.parse(json)
        active = data.fetch("branches").reject { it["isMerged"] && !it["isCurrent"] }
        entries = active.map { StackEntry.new(branch: it.fetch("name"), number: it.dig("pr", "number"), head: it["isCurrent"] == true) }
        Wt::Stack.new(trunk: data.fetch("trunk"), entries:, needs_restack: active.any? { it["needsRebase"] && !it["isMerged"] })
      end

      def self.enrich(stack, dir, timeout)
        threads = stack.entries.map do |entry|
          Thread.new do
            next entry unless entry.number

            r = Shell.capture(["gh", "pr", "view", entry.number.to_s, "--json", Pr::FIELDS], chdir: dir, env: Pr::GH_ENV, timeout:, stdin: "")
            next entry unless r.ok?

            pr = Pr.parse(r.stdout)
            entry.with(review: pr.review, ci: pr.ci, draft: pr.draft)
          rescue JSON::ParserError, KeyError
            entry
          end
        end
        stack.with(entries: threads.map(&:value))
      end
    end
  end
end
