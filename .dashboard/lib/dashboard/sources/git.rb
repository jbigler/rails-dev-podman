# frozen_string_literal: true

module Dashboard
  # Every git read here runs with Sources.git_env, whose shadow config holds no
  # key that runs a command; only these subcommands are used.
  module Sources
    # `git worktree list --porcelain` in the base worktree.
    module Worktrees
      def self.fetch(ws)
        argv = ["git", "-C", ws.base_path, "worktree", "list", "--porcelain"]
        r = Sources.check!(Shell.run(argv, env: Sources.git_env(ws)), "git worktree list")
        parse(r.stdout, base_path: ws.base_path)
      end

      # Blank-line separated records: `worktree <path>`, `HEAD <sha>`, then
      # `branch refs/heads/<name>` or `detached`. Prunable ones (folder gone) are
      # skipped. The first record is the main worktree, which git names after
      # the common dir — the GitSafety shadow — so it is given base_path.
      def self.parse(text, base_path:)
        text.split(/\n[ \t]*\n/).each_with_index.filter_map do |record, index|
          attrs = record.lines.map(&:chomp).reject(&:empty?).to_h { |l| k, v = l.split(" ", 2); [k, v] }
          path = index.zero? ? base_path : attrs["worktree"]
          next if attrs["worktree"].nil? || attrs.key?("bare") || attrs.key?("prunable")

          WorktreeRef.new(name: File.basename(path), path:, branch: attrs["branch"]&.delete_prefix("refs/heads/"),
                          head_sha: attrs["HEAD"], base: index.zero?)
        end
      end
    end

    # `git status --porcelain=v2 --branch` in one worktree of ws.
    module GitStatus
      def self.fetch(ws, path)
        r = Shell.run(["git", "-C", path, "status", "--porcelain=v2", "--branch", "--ignore-submodules=all"],
                      env: Sources.git_env(ws))
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
        r = Shell.run(["git", "-C", ws.base_path, "remote", "get-url", "origin"], env: Sources.git_env(ws))
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
      def self.fetch(ws, path, base_ref)
        return nil if base_ref.to_s.empty?

        r = Shell.run(["git", "-C", path, "rev-list", "--count", "origin/#{base_ref}..HEAD"], env: Sources.git_env(ws))
        raise Failed, "git rev-list: #{r.error_line}" if r.broken?

        r.ok? ? Integer(r.stdout.strip, 10) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
