# frozen_string_literal: true

module Wt
  # One git worktree under the workspace root. Ports derive from WORKTREE_ID
  # exactly as .mise/local.toml.template does.
  class Worktree < Data.define(:slug, :path, :branch, :head, :id, :base, :detached, :prunable)
    def initialize(slug:, path:, branch: nil, head: nil, id: nil, base: false, detached: false, prunable: false)
      super
    end

    def port(offset) = id && offset + id
    def nvim_port = port(17_000)
    def db_port = port(55_432)
    def app_port = port(13_000)
    def s3_port = port(19_000)
    def playwright_port = port(18_888)
    def debug_port = port(33_000)
    def host = "#{slug}.localhost"
  end

  # `git status --porcelain=v2 --branch` for one worktree.
  class GitStatus < Data.define(:branch, :upstream, :ahead, :behind, :dirty, :detached)
    def initialize(branch: nil, upstream: nil, ahead: 0, behind: 0, dirty: 0, detached: false)
      super
    end
  end
end
