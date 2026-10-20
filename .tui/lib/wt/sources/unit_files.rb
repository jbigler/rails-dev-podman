# frozen_string_literal: true

module Wt
  module Sources
    # Do the installed Quadlet units still match .container-config/quadlet/? Asks
    # `.scripts/quadlet.sh check-stale` — the same check `up` refuses on — rather
    # than re-rendering the templates here. `up` fails until `units:install` runs.
    module UnitFiles
      def self.fetch(config)
        argv = [File.join(config.root, ".scripts", "quadlet.sh"), "check-stale"]
        # Under `mise run tui` the mise env is already loaded; started directly, the
        # script still needs the prefix (the PODMAN_* subnet values default in it).
        env = ENV.key?("PROJECT_PREFIX") ? {} : { "PROJECT_PREFIX" => config.prefix }
        r = Shell.capture(argv, chdir: config.root, env:, timeout: config.timeout)
        raise Error, "quadlet.sh check-stale: #{r.error_line}" if r.timed_out || ![0, 1].include?(r.status)

        Msg::UnitFilesChecked.new(stale: Ractor.make_shareable(parse(r.status, r.stderr)))
      end

      # check-stale exits 0 when everything matches; 1 with one indented
      # "  <file>   <reason>" row per drifted unit on stderr.
      def self.parse(status, stderr)
        return [] if status.zero?

        stderr.lines.filter_map { |l| l[/\A {2}(\S+)\s{2,}\S/, 1] }
      end
    end
  end
end
