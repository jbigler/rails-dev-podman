# frozen_string_literal: true

module Dashboard
  module GitSafety
    # The real common config reduced to an allowlist: what status, worktree
    # list, rev-list, remote get-url, gh pr list and gh stack view need (the
    # repo format, remotes, branch upstreams). Everything else — filter.*,
    # include*, core.fsmonitor, core.hooksPath, extensions.worktreeConfig,
    # alias.*, … — is dropped. git parses the real file, with an environment
    # that reaches no repo config; the copy is written here in one pass.
    module SanitizedConfig
      ALLOWED = /\A(?:core\.(?:repositoryformatversion|bare|filemode|ignorecase|symlinks|precomposeunicode)|
                   extensions\.(?:objectformat|refstorage)|
                   remote\..+\.(?:url|fetch|gh-resolved)|
                   branch\..+\.(?:remote|merge))\z/x
      # A container can write any number of fetch lines; above this the read fails closed.
      MAX_ENTRIES = 2000
      VALUE_ESCAPES = { "\\" => "\\\\", '"' => '\\"', "\n" => "\\n", "\t" => "\\t", "\b" => "\\b" }.freeze

      # bytes: the real config, read once; scratch: a private dir to work in.
      # → [[key, value]] in file order. Raises Unsafe when git cannot list it
      # or it holds more than MAX_ENTRIES allowlisted entries.
      def self.entries(bytes, scratch)
        copy = File.join(scratch, "config.read")
        File.unlink(copy) if File.symlink?(copy) || File.exist?(copy)
        File.open(copy, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { it.write(bytes) }
        listed = git(["config", "--no-includes", "--file", copy, "--list", "-z"], scratch)
        kept = listed.split("\0").filter_map do |entry|
          key, value = entry.split("\n", 2)
          # A bare `key` line is boolean true; only core's booleans may be one.
          value ||= "true" if key.start_with?("core.")
          [key, value] if value && key.match?(ALLOWED)
        end
        raise Unsafe, "git config: more than #{MAX_ENTRIES} remote/branch entries" if kept.size > MAX_ENTRIES

        kept
      ensure
        File.unlink(copy) if copy && File.exist?(copy)
      end

      # Writes entries to a new file at path (0600) in git config syntax.
      def self.write(entries, path)
        File.unlink(path) if File.symlink?(path) || File.exist?(path)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { it.write(text(entries)) }
      end

      # git lists a key as section[.subsection].name, section and name lowercase
      # and dot-free, the subsection verbatim (dots included, no newline).
      def self.text(entries)
        header = nil
        entries.each_with_object(+"") do |(key, value), out|
          section, rest = key.split(".", 2)
          sub, _, name = rest.rpartition(".")
          raise Unsafe, "git config: bad key #{key.inspect}" if name.empty? || sub.include?("\n")

          want = sub.empty? ? "[#{section}]\n" : %([#{section} "#{sub.gsub(/["\\]/) { "\\#{it}" }}"]\n)
          out << want unless want == header
          header = want
          out << %(\t#{name} = "#{value.gsub(/[\\"\n\t\b]/, VALUE_ESCAPES)}"\n)
        end
      end
      private_class_method :text

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
