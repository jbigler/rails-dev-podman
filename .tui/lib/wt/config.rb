# frozen_string_literal: true

module Wt
  # Where the workspace lives and how wt was asked to look. Built once at boot from
  # the environment `mise run tui` exports, then frozen into the model.
  class Config < Data.define(
    :root,          # workspace (wrapper) root: holds .mise/, .scripts/, ports.registry
    :prefix,        # PROJECT_PREFIX: <prefix>-<svc>@<slug>.service, <prefix>-<slug>-<svc>
    :base_name,     # base worktree dir name (the one with a .git directory)
    :theme,         # :light | :dark (WT_THEME)
    :accent,        # :orange | :cyan | :purple | :blue (WT_ACCENT)
    :timeout,       # seconds every source call may take (default 5)
    :action_timeout # seconds a mise action task may take before it is killed
  )
    def self.discover(start = Dir.pwd, env: ENV)
      root = find_root(env.fetch("WT_ROOT", nil) || start)
      raise Error, "not inside a rails-dev-podman workspace (no .mise/config.toml + .scripts/ above #{start})" unless root

      new(
        root:,
        prefix: env.fetch("PROJECT_PREFIX", "default"),
        base_name: find_base(root),
        theme: env.fetch("WT_THEME", "light") == "dark" ? :dark : :light,
        accent: ACCENTS.find { it.to_s == env.fetch("WT_ACCENT", "orange") } || :orange,
        timeout: Float(env.fetch("WT_TIMEOUT", "5")),
        action_timeout: Float(env.fetch("WT_ACTION_TIMEOUT", "1800"))
      )
    end

    ACCENTS = %i[orange cyan purple blue].freeze

    def self.find_root(start)
      dir = File.expand_path(start)
      loop do
        return dir if File.file?(File.join(dir, ".mise", "config.toml")) && File.directory?(File.join(dir, ".scripts"))
        parent = File.dirname(dir)
        return nil if parent == dir
        dir = parent
      end
    end

    def self.find_base(root)
      Dir.children(root).sort.find { |d| File.directory?(File.join(root, d, ".git")) }
    end

    def base_path = base_name && File.join(root, base_name)
    def worktree_path(slug) = File.join(root, slug)
    def status_dir = File.join(root, ".container-config", "status")
    def status_file(slug) = File.join(status_dir, "#{slug}.json")
    def run_dir(slug) = File.join(root, ".run", slug)
    def acp_socket(slug) = File.join(run_dir(slug), "acp.sock")
    def session_log(slug) = File.join(run_dir(slug), "session.jsonl")
    def registry_path = File.join(root, "ports.registry")
    def unit_name(svc, slug) = "#{prefix}-#{svc}@#{slug}.service"
    def container_name(svc, slug) = "#{prefix}-#{slug}-#{svc}"
  end

  class Error < StandardError; end
end
