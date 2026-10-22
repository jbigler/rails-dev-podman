# frozen_string_literal: true

module Dashboard
  # Every git read here runs with Sources.git_env. Only these subcommands are
  # used: config keys that run commands but GitSafety does not override
  # (diff.external, textconv, core.pager, core.sshCommand, credential.helper)
  # belong to diff, log -p, fetch and push, which the dashboard never reads.
  module Sources
    # `git worktree list --porcelain` in the base worktree.
    module Worktrees
      def self.fetch(ws)
        argv = ["git", "-C", ws.base_path, "worktree", "list", "--porcelain"]
        r = Sources.check!(Shell.run(argv, env: Sources.git_env(ws.base_path)), "git worktree list")
        parse(r.stdout, base_path: ws.base_path)
      end

      # Blank-line separated records: `worktree <path>`, `HEAD <sha>`, then
      # `branch refs/heads/<name>` or `detached`. Prunable ones (folder gone) are skipped.
      def self.parse(text, base_path:)
        text.split(/\n[ \t]*\n/).filter_map do |record|
          attrs = record.lines.map(&:chomp).reject(&:empty?).to_h { |l| k, v = l.split(" ", 2); [k, v] }
          path = attrs["worktree"]
          next if path.nil? || attrs.key?("bare") || attrs.key?("prunable")

          WorktreeRef.new(name: File.basename(path), path:, branch: attrs["branch"]&.delete_prefix("refs/heads/"),
                          head_sha: attrs["HEAD"], base: path == base_path)
        end
      end
    end

    # `git status --porcelain=v2 --branch` in one worktree.
    module GitStatus
      def self.fetch(path)
        r = Shell.run(["git", "-C", path, "status", "--porcelain=v2", "--branch", "--ignore-submodules=all"],
                      env: Sources.git_env(path))
        parse(Sources.check!(r, "git status").stdout)
      end

      # `# branch.ab +A -B` is absent without an upstream: ahead/behind stay nil.
      # dirty_count counts tracked changes only; `? ` untracked lines (every
      # worktree has an untracked .local/) are ignored.
      def self.parse(text)
        ahead = behind = upstream = nil
        dirty = 0
        text.each_line do |line|
          case line
          when /\A# branch\.ab \+(\d+) -(\d+)/ then ahead, behind = Integer($1, 10), Integer($2, 10)
          when /\A# branch\.upstream (\S+)/ then upstream = $1.split("/").first
          when /\A[12u] / then dirty += 1
          end
        end
        GitInfo.new(ahead:, behind:, upstream:, dirty_count: dirty)
      end
    end

    # `git remote get-url origin` → "owner/name" for the header.
    module Repo
      def self.fetch(ws)
        r = Shell.run(["git", "-C", ws.base_path, "remote", "get-url", "origin"], env: Sources.git_env(ws.base_path))
        parse(Sources.check!(r, "git remote").stdout)
      end

      def self.parse(url)
        url = url.strip
        url[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?/?\z}, 1] || url
      end
    end

    # The commit count shown for an open PR, computed locally instead of per-PR
    # `gh pr view`: `git rev-list --count origin/<base>..HEAD` in the worktree.
    module CommitCount
      # → Integer, or nil without a base or when origin/<base> is not known
      # here (not fetched yet). A hung or missing git is a failure.
      def self.fetch(path, base_ref)
        return nil if base_ref.to_s.empty?

        r = Shell.run(["git", "-C", path, "rev-list", "--count", "origin/#{base_ref}..HEAD"], env: Sources.git_env(path))
        raise Failed, "git rev-list: #{r.error_line}" if r.broken?

        r.ok? ? Integer(r.stdout.strip, 10) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
