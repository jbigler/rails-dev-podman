# frozen_string_literal: true

module Dashboard
  # The dashboard's host-private directory, never mounted into a container:
  # $XDG_RUNTIME_DIR/<prefix>-dashboard, else <tmpdir>/<prefix>-dashboard-<uid>.
  # It holds the git shadow common dir and the job logs.
  module PrivateDir
    # → the path, created mode 0700. Raises Error when it is anything but a
    # directory of this user that no one else can enter.
    def self.for(prefix, env: ENV)
      runtime = env["XDG_RUNTIME_DIR"].to_s
      base = if !runtime.empty? && File.directory?(runtime)
               File.join(runtime, "#{prefix}-dashboard")
             else
               File.join(Dir.tmpdir, "#{prefix}-dashboard-#{Process.uid}")
             end
      make(base)
    end

    # Creates `path` mode 0700 unless it exists, then checks it as above. → path
    def self.make(path)
      begin
        Dir.mkdir(path, 0o700)
      rescue Errno::EEXIST
        nil
      end
      st = File.lstat(path)
      return path if st.directory? && st.uid == Process.uid && (st.mode & 0o077).zero?

      raise Error, "#{path}: not a directory only this user can enter"
    end
  end
end
