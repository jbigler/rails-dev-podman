# frozen_string_literal: true

module Wt
  # Stack keys `[` `]` `R` `P` `p` on the focused worktree. The four stack
  # operations are github/gh-stack subcommands (spec: wt's one exception for
  # stack operations); `down` moves toward trunk, `up` away from it, `rebase`
  # fetches and cascades the whole stack, `push` pushes every active branch.
  module Actions
    STACK_OPS = Ractor.make_shareable({
      stack_down: ["stack down", %w[gh stack down]],
      stack_up: ["stack up", %w[gh stack up]],
      restack: ["restack", %w[gh stack rebase]],
      push_stack: ["push stack", %w[gh stack push]]
    })

    def self.stack_down(model) = stack_op(model, :stack_down)
    def self.stack_up(model) = stack_op(model, :stack_up)
    def self.restack(model) = stack_op(model, :restack)
    def self.push_stack(model) = stack_op(model, :push_stack)

    def self.stack_op(model, op)
      wt = model.worktree(model.focus_slug)
      return model unless wt

      label, argv = STACK_OPS.fetch(op)
      [model, Ractor.make_shareable(Commands::StackOp.new(config: model.config, worktree: wt, label:, argv:))]
    end

    # Opens the branch's PR in the browser. A branch known to have none gets a
    # toast instead of gh's error.
    def self.open_pr(model)
      wt = model.worktree(model.focus_slug)
      return model unless wt
      return model.notify("#{wt.slug}: no PR for #{wt.branch || 'this checkout'}") if model.prs[wt.slug] == :none

      [model, Commands.exec(model, "open PR", wt.slug, %w[gh pr view --web], cwd: wt.path)]
    end
  end
end
