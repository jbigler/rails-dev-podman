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

    # The filter drivers could not be listed, so no safe environment exists.
    # Callers treat it as a failed read.
    class Unsafe < Error; end

    # Not cached: a filter can arrive through any include.path file, whose
    # mtime no cache key here would see.
    def self.env(path)
      config_env(OVERRIDES.merge(filter_keys(path).to_h { [it, ""] }))
    end

    # Exit 1 with no output is "no match"; anything else short of success
    # (a timeout, a config git cannot parse) fails closed.
    def self.filter_keys(path)
      read = Shell.run(["git", "-C", path, "config", "--name-only", "--get-regexp", FILTER_KEYS],
                       env: config_env(OVERRIDES))
      return [] if !read.timed_out && read.status == 1 && read.stdout.empty?
      raise Unsafe, "cannot list filter drivers in #{path}: #{read.error_line}" unless read.ok?

      read.stdout.lines(chomp: true).reject(&:empty?)
    end

    def self.config_env(pairs)
      env = { "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_COUNT" => pairs.size.to_s }
      pairs.each_with_index do |(key, value), n|
        env["GIT_CONFIG_KEY_#{n}"] = key
        env["GIT_CONFIG_VALUE_#{n}"] = value
      end
      env
    end
    private_class_method :filter_keys, :config_env
  end
end
