# frozen_string_literal: true

module Dashboard
  # The environment every background git (and gh, which runs git) call gets.
  # Containers can write master/.git and the worktrees, so repo config must not
  # turn into code the host runs unattended. git never reads the real common
  # dir: GIT_COMMON_DIR points at a host-private shadow (GitSafety::Shadow)
  # whose config holds only allowlisted keys, so no filter, include, fsmonitor
  # or hooksPath a container wrote ever reaches it, however the real file
  # changes between reads. The overrides stay as defence in depth (GIT_CONFIG_*
  # entries count as command-line config, which wins over files); submodules,
  # whose own config is never sanitized, are not entered.
  module GitSafety
    OVERRIDES = { "core.fsmonitor" => "false", "core.hooksPath" => "/dev/null",
                  "diff.ignoreSubmodules" => "all", "submodule.recurse" => "false" }.freeze

    # No safe environment could be built (the shadow failed). Callers treat it
    # as a failed read and run nothing.
    class Unsafe < Error; end

    # One Shadow per workspace, in its PrivateDir. env: where XDG_RUNTIME_DIR comes from.
    class Shadows
      def initialize(env: ENV)
        @env = env
        @lock = Mutex.new
        @shadows = {}
      end

      def env(ws) = shadow(ws).env

      private

      def shadow(ws)
        @lock.synchronize do
          @shadows[[ws.prefix, ws.base_path]] ||=
            Shadow.new(git_dir: File.join(ws.base_path, ".git"), home: PrivateDir.for(ws.prefix, env: @env))
        end
      rescue Error, SystemCallError => e
        raise Unsafe, "git safety: #{e.message}"
      end
    end

    class << self
      attr_writer :backend

      def backend = @backend ||= Shadows.new

      # → the env for a git or gh call in any worktree of ws. Raises Unsafe.
      def env(ws) = backend.env(ws)

      # OVERRIDES as GIT_CONFIG_* entries, plus GIT_OPTIONAL_LOCKS=0 (a read never writes the index).
      def overrides_env
        env = { "GIT_OPTIONAL_LOCKS" => "0", "GIT_CONFIG_COUNT" => OVERRIDES.size.to_s }
        OVERRIDES.each_with_index do |(key, value), n|
          env["GIT_CONFIG_KEY_#{n}"] = key
          env["GIT_CONFIG_VALUE_#{n}"] = value
        end
        env
      end
    end
  end
end
