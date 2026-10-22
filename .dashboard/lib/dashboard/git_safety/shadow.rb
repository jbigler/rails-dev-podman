# frozen_string_literal: true

require "fileutils"

module Dashboard
  module GitSafety
    # One workspace's shadow common dir, <home>/gitcommon: a SanitizedConfig
    # of the real common config, and symlinks to the real refs and objects.
    # info/ (attributes, exclude), hooks/ and the real config are never
    # linked. The config is regenerated when the real file's bytes change;
    # git only ever reads the copy, so a container rewriting the real file
    # between two reads changes nothing.
    class Shadow
      LINKS = %w[HEAD objects refs packed-refs shallow worktrees gh-stack reftable].freeze
      CONFIG_LIMIT = 1024 * 1024

      # git_dir: the base worktree's .git; home: a PrivateDir.
      def initialize(git_dir:, home:)
        @git_dir = git_dir
        @home = home
        @dir = File.join(home, "gitcommon")
        @lock = Mutex.new
        @read = nil
      end

      # → GIT_COMMON_DIR plus the overrides. Raises Unsafe when the shadow
      # cannot be brought up to date: git must not run then.
      def env
        @lock.synchronize { refresh }
        GitSafety.overrides_env.merge("GIT_COMMON_DIR" => @dir)
      rescue Unsafe
        raise
      rescue Error, SystemCallError => e
        raise Unsafe, "git safety: #{e.message}"
      end

      private

      def refresh
        bytes = SafeFile.read(File.join(@git_dir, "config"), limit: CONFIG_LIMIT)
        return if bytes == @read

        build unless @read
        entries = SanitizedConfig.entries(bytes, @home)
        fresh = File.join(@dir, "config.new")
        SanitizedConfig.write(entries, fresh, @home)
        File.rename(fresh, File.join(@dir, "config"))
        @read = bytes
      end

      # A fresh dir of links; one to an entry the repo lacks (gh-stack,
      # shallow, reftable on a files-backend repo) reads as absent.
      def build
        FileUtils.rm_rf(@dir)
        Dir.mkdir(@dir, 0o700)
        LINKS.each { File.symlink(File.join(@git_dir, it), File.join(@dir, it)) }
      end
    end
  end
end
