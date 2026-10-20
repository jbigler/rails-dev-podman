# frozen_string_literal: true

module Wt
  module Acp
    # `mise run agent:up` in the worktree, as Commands::MiseTask runs it, reporting
    # Msg::AgentUpFinished so a failure can also end the session's "connecting…".
    class Up < Data.define(:slug, :cwd, :timeout)
      include Rooibos::Command::Custom

      def call(out, _token)
        r = Shell.capture(%w[mise run agent:up], chdir: cwd, env: { "NO_COLOR" => "1" }, timeout:, stdin: "")
        msg = Msg::AgentUpFinished.new(slug:, status: r.timed_out ? -1 : r.status, stderr: r.timed_out ? "timed out" : r.stderr)
        out.put(Ractor.make_shareable(msg))
      end
    end

    def self.up(model, slug) = Up.new(slug: -slug, cwd: -model.config.worktree_path(slug), timeout: model.config.action_timeout)
  end
end
