# frozen_string_literal: true

module Dashboard
  # ROOT, the project prefix, the base worktree and the dashboard's own port
  # (§3.2). Built once at boot.
  class Workspace < Data.define(:root, :prefix, :base_name, :port)
    SERVICES = [%w[rails rails], %w[postgres db], %w[redis redis], %w[rustfs rustfs], %w[playwright playwright], %w[nvim nvim]].freeze # [label, unit svc]
    PORT_KEYS = { "rails" => "APP_PORT", "db" => "DB_PORT", "rustfs" => "S3_PORT", "playwright" => "PLAYWRIGHT_HOST_PORT", "nvim" => "NVIM_PORT" }.freeze

    def initialize(root:, prefix:, base_name:, port: nil) = super

    # ROOT is found from the working directory ($WT_ROOT overrides) by walking
    # up to the dir holding the base. The prefix comes from the environment
    # `mise run` gives the dashboard; it never runs `mise env` itself.
    def self.discover(env: ENV, cwd: Dir.pwd)
      start = File.expand_path(env["WT_ROOT"] || cwd)
      root, base = candidates(start).lazy.filter_map { |dir| (b = find_base(dir)) && [dir, b] }.first
      raise Error, "no base worktree (a folder whose .git is a directory) under #{start} or above" unless root

      new(root:, prefix: env["PROJECT_PREFIX"] || File.basename(root), base_name: base, port: env["WT_DASHBOARD_PORT"])
    end

    def self.candidates(dir)
      dirs = [dir]
      dirs << (dir = File.dirname(dir)) until File.dirname(dir) == dir
      dirs
    end

    def self.find_base(dir)
      return nil unless File.directory?(dir)

      Dir.children(dir).sort.find { File.directory?(File.join(dir, it, ".git")) }
    end
    private_class_method :candidates, :find_base

    def base_path = File.join(root, base_name)
    def path(name) = File.join(root, name)
    def status_dir = File.join(root, ".container-config", "status")
    def status_file(name) = File.join(status_dir, "#{name}.json")
    def unit_env_file(name) = File.join(root, ".unit-env", "#{name}.env")
    def unit(svc, name) = "#{prefix}-#{svc}@#{name}.service"
    def dashboard_unit = "#{prefix}-dashboard.service"
    def container(name, svc) = "#{prefix}-#{name}-#{svc}"
    def newterm = File.join(root, ".scripts", "newterm.sh")
  end
end
