# frozen_string_literal: true

module Wt
  # `gh pr view --json number,title,state,isDraft,reviewDecision,statusCheckRollup`.
  #   ci: :pass | :fail | :pending | :none
  class PrStatus < Data.define(:number, :title, :state, :draft, :review, :ci, :ci_passed, :ci_failed, :ci_total, :failing)
    def initialize(number:, title: "", state: "OPEN", draft: false, review: nil, ci: :none, ci_passed: 0, ci_failed: 0, ci_total: 0, failing: [])
      super
    end
  end

  # One branch of a gh stack, bottom (closest to trunk) first.
  class StackEntry < Data.define(:branch, :number, :review, :ci, :draft, :head)
    def initialize(branch:, number: nil, review: nil, ci: :none, draft: false, head: false)
      super
    end
  end

  # The stack a worktree's HEAD sits in. entries are ordered trunk-up; position is
  # 1-based index of HEAD (nil when HEAD is not in a stack).
  class Stack < Data.define(:trunk, :entries, :needs_restack)
    def initialize(trunk: "main", entries: [], needs_restack: false)
      super
    end

    def position = (i = entries.index(&:head)) && i + 1
    def size = entries.size
  end
end
