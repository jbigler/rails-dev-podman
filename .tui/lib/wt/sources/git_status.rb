# frozen_string_literal: true

module Wt
  module Sources
    # `git status --porcelain=v2 --branch` for one worktree.
    module GitStatus
      def self.fetch(config, slug)
        res = Shell.capture(["git", "-C", config.worktree_path(slug), "status", "--porcelain=v2", "--branch"],
                            timeout: config.timeout)
        raise Error, "git status #{slug}: #{res.error_line}" unless res.ok?

        Msg::GitStatusLoaded.new(slug:, status: parse(res.stdout))
      end

      ENTRY = /\A[12u?] /

      def self.parse(text)
        branch = upstream = nil
        ahead = behind = dirty = 0
        detached = false
        text.each_line(chomp: true) do |line|
          case line
          when /\A# branch\.head (.+)\z/
            detached = Regexp.last_match(1) == "(detached)"
            branch = detached ? nil : Regexp.last_match(1)
          when /\A# branch\.upstream (.+)\z/ then upstream = Regexp.last_match(1)
          when /\A# branch\.ab \+(\d+) -(\d+)\z/
            ahead = Integer(Regexp.last_match(1))
            behind = Integer(Regexp.last_match(2))
          when ENTRY then dirty += 1
          end
        end
        Wt::GitStatus.new(branch: branch&.freeze, upstream: upstream&.freeze, ahead:, behind:, dirty:, detached:)
      end
    end
  end
end
