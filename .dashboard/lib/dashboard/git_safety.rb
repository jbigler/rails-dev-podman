# frozen_string_literal: true

module Dashboard
  # The environment every background git (and gh, which runs git) call gets.
  # Containers can write master/.git and the worktrees, so repo config must not
  # turn into code the host runs unattended: fsmonitor and hooks are switched
  # off and every configured filter driver is blanked. GIT_CONFIG_* entries
  # count as command-line config, which wins over files and includes.
  module GitSafety
    OVERRIDES = { "core.fsmonitor" => "false", "core.hooksPath" => "/dev/null" }.freeze
    FILTER_KEYS = '^filter\..*\.(clean|smudge|process)$'

    # Not cached: a filter can arrive through any include.path file, whose
    # mtime no cache key here would see.
    def self.env(path)
      base = config_env(OVERRIDES)
      read = Shell.run(["git", "-C", path, "config", "--name-only", "--get-regexp", FILTER_KEYS], env: base)
      filters = read.ok? ? read.stdout.lines(chomp: true).reject(&:empty?) : []
      config_env(OVERRIDES.merge(filters.to_h { [it, ""] }))
    end

    def self.config_env(pairs)
      env = { "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_COUNT" => pairs.size.to_s }
      pairs.each_with_index do |(key, value), n|
        env["GIT_CONFIG_KEY_#{n}"] = key
        env["GIT_CONFIG_VALUE_#{n}"] = value
      end
      env
    end
    private_class_method :config_env
  end
end
