# frozen_string_literal: true

require "tempfile"

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

    # `gh pr view --web` in a worktree. A browser started through xdg-open inherits
    # gh's stdout/stderr, so they are never pipes wt drains: stdout goes to
    # /dev/null and stderr to a temp file read once gh itself exits (or times out).
    class OpenPr < Data.define(:slug, :cwd, :timeout)
      include Rooibos::Command::Custom

      ARGV = %w[gh pr view --web].freeze

      def call(out, _token)
        status, stderr = Tempfile.create("wt-open-pr") do |err|
          pid = Process.spawn(Sources::Pr::GH_ENV, *ARGV, chdir: cwd, in: File::NULL, out: File::NULL, err: err, pgroup: true)
          waiter = Process.detach(pid)
          if waiter.join(timeout)
            [waiter.value.exitstatus || -1, File.read(err.path)]
          else
            Shell.kill_group(pid)
            [-1, "timed out"]
          end
        rescue Errno::ENOENT, Errno::EACCES => e
          [127, e.message]
        end
        out.put(Ractor.make_shareable(Msg::CommandFinished.new(label: "open PR", slug:, status:, stderr: stderr.freeze, refresh: false)))
      end
    end
  end
end
