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
    #
    # worktrees/ is a real directory holding a real directory per worktree,
    # whose entries link to that worktree's real admin files: gh-stack lstats
    # both levels and refuses a symlink ("worktree administration path … is not
    # a directory"). It follows worktrees being added and removed.
    class Shadow
      LINKS = %w[HEAD objects refs packed-refs shallow gh-stack reftable].freeze
      # Read only with extensions.worktreeConfig, which the sanitized config
      # never carries; not linked all the same.
      SKIP_ADMIN = %w[config.worktree].freeze
      CONFIG_LIMIT = 1024 * 1024

      # git_dir: the base worktree's .git; home: a PrivateDir.
      def initialize(git_dir:, home:)
        @git_dir = git_dir
        @home = home
        @dir = File.join(home, "gitcommon")
        @lock = Mutex.new
        @read = nil
        @admins = {}
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
        unless bytes == @read
          build unless @read
          entries = SanitizedConfig.entries(bytes, @home)
          fresh = File.join(@dir, "config.new")
          SanitizedConfig.write(entries, fresh)
          File.rename(fresh, File.join(@dir, "config"))
          @read = bytes
        end
        sync_worktrees
      end

      # A fresh dir of links; one to an entry the repo lacks (gh-stack,
      # shallow, reftable on a files-backend repo) reads as absent.
      def build
        FileUtils.rm_rf(@dir)
        Dir.mkdir(@dir, 0o700)
        LINKS.each { File.symlink(File.join(@git_dir, it), File.join(@dir, it)) }
        Dir.mkdir(File.join(@dir, "worktrees"), 0o700)
        @admins = {}
      end

      # Mirrors <git_dir>/worktrees/<name>/ for every real directory there,
      # re-linking one when its mtime moved (an entry added, removed or
      # renamed into place) and dropping those that are gone.
      def sync_worktrees
        real = File.join(@git_dir, "worktrees")
        mirror = File.join(@dir, "worktrees")
        current = {}
        (File.directory?(real) ? Dir.children(real) : []).each do |name|
          st = File.lstat(File.join(real, name))
          current[name] = st.mtime if st.directory?
        rescue SystemCallError
          next
        end
        (Dir.children(mirror) - current.keys).each { FileUtils.rm_rf(File.join(mirror, it)) }
        current.each do |name, mtime|
          next if @admins[name] == mtime

          mirror_admin(File.join(real, name), File.join(mirror, name))
        end
        @admins = current
      end

      # Built beside the old copy and swapped in, so a git already running
      # never sees the admin dir half-made.
      def mirror_admin(src, dst)
        fresh = "#{dst}.new"
        FileUtils.rm_rf(fresh)
        Dir.mkdir(fresh, 0o700)
        (Dir.children(src) - SKIP_ADMIN).each { File.symlink(File.join(src, it), File.join(fresh, it)) }
        old = "#{dst}.old"
        File.rename(dst, old) if File.exist?(dst)
        File.rename(fresh, dst)
        FileUtils.rm_rf(old)
      end
    end
  end
end
