# frozen_string_literal: true

module Dashboard
  module GitSafety
    # The real common config reduced to an allowlist: what status, worktree
    # list, rev-list, remote get-url, gh pr list and gh stack view need (the
    # repo format, remotes, branch upstreams). Everything else — filter.*,
    # include*, core.fsmonitor, core.hooksPath, extensions.worktreeConfig,
    # alias.*, … — is dropped. git parses and writes the files itself, with an
    # environment that reaches no repo config.
    module SanitizedConfig
      ALLOWED = /\A(?:core\.(?:repositoryformatversion|bare|filemode|ignorecase|symlinks|precomposeunicode)|
                   extensions\.(?:objectformat|refstorage)|
                   remote\..+\.(?:url|fetch|gh-resolved)|
                   branch\..+\.(?:remote|merge))\z/x

      # bytes: the real config, read once; scratch: a private dir to work in.
      # → [[key, value]] in file order. Raises Unsafe when git cannot list it.
      def self.entries(bytes, scratch)
        copy = File.join(scratch, "config.read")
        File.unlink(copy) if File.symlink?(copy) || File.exist?(copy)
        File.open(copy, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { it.write(bytes) }
        listed = git(["config", "--no-includes", "--file", copy, "--list", "-z"], scratch)
        listed.split("\0").filter_map do |entry|
          key, value = entry.split("\n", 2)
          # A bare `key` line is boolean true; only core's booleans may be one.
          value ||= "true" if key.start_with?("core.")
          [key, value] if value && key.match?(ALLOWED)
        end
      ensure
        File.unlink(copy) if copy && File.exist?(copy)
      end

      # Writes entries to a new file at path (0600). Raises Unsafe when git refuses one.
      def self.write(entries, path, scratch)
        File.unlink(path) if File.symlink?(path) || File.exist?(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { nil }
        entries.each { |key, value| git(["config", "--file", path, "--add", key, value], scratch) }
      end

      # Repo discovery stops at scratch (ours, not a repo); no system or global config.
      def self.git(args, scratch)
        env = { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => File::NULL,
                "GIT_CEILING_DIRECTORIES" => File.dirname(scratch) }
        r = Shell.run(["git", *args], chdir: scratch, env:)
        raise Unsafe, "git config: #{r.error_line}" unless r.ok?

        r.stdout
      end
      private_class_method :git
    end
  end
end
