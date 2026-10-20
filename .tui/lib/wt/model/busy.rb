# frozen_string_literal: true

module Wt
  # A mise action wt started and is waiting on ("up", "units:install → up"). Shown
  # from the key press until its Msg::CommandFinished, so a slow `up` is visibly
  # under way before podman reports any container.
  class Busy < Data.define(:label, :since)
    # The worktree slug (nil = the workspace root) => Busy for every tracked action
    # inside `cmd` (a command, or a batch holding some). Only actions that report a
    # CommandFinished for that slug are tracked, so every entry is cleared again.
    def self.started(cmd, now)
      case cmd
      when Commands::MiseTask then { cmd.slug => new(label: cmd.label, since: now) }
      when Commands::MiseChain then { cmd.slug => new(label: cmd.tasks.map(&:label).join(" → "), since: now) }
      when Commands::StackOp then { cmd.worktree.slug => new(label: cmd.label, since: now) }
      when Rooibos::Command::Batch then cmd.commands.map { started(it, now) }.reduce({}, :merge)
      else {}
      end
    end
  end
end
