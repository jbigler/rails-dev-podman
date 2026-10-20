# frozen_string_literal: true

module Wt
  module Commands
    # A gh stack operation (`gh stack up|down|rebase|push`) in one worktree. Spec
    # "Before stack operations": nvim's modified buffers are written first (`:wa`
    # over its socket), and a failed write refuses the operation — the branch is
    # never switched or rebased under unsaved edits. Reports Msg::CommandFinished;
    # a run that went ahead refreshes everything (HEAD and the stack moved).
    class StackOp < Data.define(:config, :worktree, :label, :argv)
      include Rooibos::Command::Custom

      def call(out, _token)
        saved = Nvim.write_all(config, worktree)
        msg = if saved.ok?
                r = Shell.capture(argv, chdir: worktree.path, env: Sources::Pr::GH_ENV, timeout: config.action_timeout, stdin: "")
                Msg::CommandFinished.new(label:, slug: worktree.slug, status: r.timed_out ? -1 : r.status,
                                         stderr: r.timed_out ? "timed out" : r.stderr, refresh: true)
              else
                Msg::CommandFinished.new(label:, slug: worktree.slug, status: 1, stderr: "nvim :wa failed: #{saved.error_line}", refresh: false)
              end
        out.put(Ractor.make_shareable(msg))
      end
    end
  end
end
