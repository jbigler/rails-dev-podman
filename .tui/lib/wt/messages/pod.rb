# frozen_string_literal: true

module Wt
  module Msg
    # podman events saw a container of this workspace change (Commands::PodmanEvents,
    # debounced). Refetch every worktree's units now instead of waiting for the 2 s tick.
    class UnitsDirty < Data.define
      include Message
      def apply(model) = Refresh.schedule(model, [Refresh.units(model)])
    end

    # Dispatches `command` from Update. Rooibos only tracks (and so can only cancel)
    # commands returned at the top level, and a Command::Cancel inside a batch is never
    # honoured; delivering this message lets one action start and cancel commands
    # (`L` switching the followed log) as separate top-level dispatches.
    class RunCommand < Data.define(:command)
      include Message
      def apply(model) = [model, command]
    end
  end
end
