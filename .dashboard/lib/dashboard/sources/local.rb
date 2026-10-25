# frozen_string_literal: true

module Dashboard
  module Sources
    # `.unit-env/<W>.env` (plain KEY=VALUE, written by units:env): the ports and
    # hosts. Read instead of `mise env`, which could run a container-written
    # mise.local.toml's exec() templates. No file: the worktree was never
    # brought up, so its ports are unknown.
    module UnitEnv
      KEYS = %w[WORKTREE_HOST S3_HOST RUSTFS_UI_HOST APP_PORT DB_PORT S3_PORT PLAYWRIGHT_HOST_PORT NVIM_PORT].freeze

      # known: name => mtime already loaded. → { changed: name => [mtime, Hash], gone: [names] }
      def self.fetch(ws, names, known)
        Sources.reread(names, known, ws.method(:unit_env_file)) { parse(it) }
      end

      # Only KEYS are kept: the file also holds POSTGRES_PASSWORD.
      def self.parse(text)
        text.each_line.filter_map do |line|
          line = line.strip
          next if line.empty? || line.start_with?("#") || !line.include?("=")

          line.split("=", 2)
        end.to_h.slice(*KEYS)
      end
    end

    # One `systemctl --user show` for every unit the dashboard displays.
    module Units
      def self.fetch(units)
        return {} if units.empty?

        r = Shell.run(["systemctl", "--user", "show", "-p", "Id,ActiveState,SubState,Result", *units])
        parse(Sources.check!(r, "systemctl").stdout)
      end

      # Records separated by blank lines → unit id => { "ActiveState" => …, … }.
      def self.parse(text)
        text.split(/\n[ \t]*\n/).filter_map do |block|
          props = block.lines.map(&:chomp).reject(&:empty?).to_h { it.split("=", 2) }
          [props["Id"], props] if props["Id"]
        end.to_h
      end
    end

    # One `podman ps -a --format json`.
    module Containers
      def self.fetch
        parse(Sources.check!(Shell.run(%w[podman ps -a --format json]), "podman ps").stdout)
      end

      # name => Container. Health is the word in parentheses of Status
      # ("Up 2 hours (healthy)"); StartedAt is epoch seconds.
      def self.parse(text)
        list = text.strip.empty? ? [] : Sources.json(text, "podman ps")
        list.each_with_object({}) do |c, out|
          started = c["StartedAt"].to_i
          Array(c["Names"]).each do |name|
            out[name] = Container.new(name:, state: c["State"].to_s, health: c["Status"].to_s[/\((healthy|unhealthy|starting)\)/, 1],
                                      exit_code: c["ExitCode"].to_i, started_at: started.positive? ? Time.at(started) : nil)
          end
        end
      end
    end

    # The Claude status files (§6.2), re-read only when their mtime changed.
    module AgentFiles
      # known: name => mtime already loaded. → { changed: name => [mtime, StatusFile], gone: [names] }
      def self.fetch(ws, names, known)
        Sources.reread(names, known, ws.method(:status_file)) { parse(it) }
      end

      # Each field must have its type, else it is absent (v: 0); not an object → nil.
      def self.parse(text)
        h = JSON.parse(text)
        return nil unless h.is_a?(Hash)

        str = ->(key) { h[key].is_a?(String) ? h[key] : nil }
        ts = begin
          str.("ts")&.then { Time.iso8601(it) }
        rescue ArgumentError
          nil
        end
        StatusFile.new(v: h["v"].is_a?(Integer) ? h["v"] : 0, state: str.("state"), phase: str.("phase"), ts:,
                       message: str.("message"), tool: str.("tool"), last_message: str.("last_message"),
                       rtk: rtk(h["rtk"]))
      rescue JSON::ParserError
        nil
      end

      RTK_MAX = 1e15

      # The hook's rtk object as an Rtk: each field kept only when a finite number
      # in 0...RTK_MAX (JSON can say 1e400, which parses to Infinity); none kept → nil.
      def self.rtk(h)
        return nil unless h.is_a?(Hash)

        fields = Rtk.members.to_h do |key|
          n = h[key.to_s]
          [key, (n.is_a?(Integer) || n.is_a?(Float)) && n.finite? && n >= 0 && n < RTK_MAX ? n : nil]
        end
        fields.values.any? ? Rtk.new(**fields) : nil
      end
    end

    # `quadlet.sh check-stale`: the installed units that no longer match their
    # templates, one "<file> <why>" line each.
    module StaleUnits
      HEADER = "no longer match"

      # Exit 0 is none stale. A failure that names no unit (the script died,
      # e.g. podman info failed) is a failed read.
      def self.fetch(ws)
        r = Shell.run([File.join(ws.root, ".scripts", "quadlet.sh"), "check-stale"], chdir: ws.root,
                      env: { "PROJECT_PREFIX" => ws.prefix })
        return [] if r.ok?

        lines = r.broken? ? [] : parse(r.stderr)
        raise Failed, "quadlet.sh check-stale: #{r.error_line}" if lines.empty?

        lines
      end

      # The block after the header line, up to the next blank line.
      def self.parse(text)
        blocks = text.split(/\n[ \t]*\n/)
        at = blocks.index { it.include?(HEADER) }
        return [] unless at && blocks[at + 1]

        blocks[at + 1].lines.map { it.strip.squeeze(" ") }.reject(&:empty?)
      end
    end

    # `systemctl --user is-enabled <prefix>-dashboard.service`: the "Start at
    # login" switch. Any other answer (not-found, masked, static, no user
    # manager) is :unknown.
    module Autostart
      STATES = { "enabled" => :enabled, "disabled" => :disabled }.freeze

      def self.fetch(ws)
        r = Shell.run(["systemctl", "--user", "is-enabled", ws.dashboard_unit])
        r.broken? ? UNKNOWN : STATES.fetch(r.stdout.strip, UNKNOWN)
      end
    end
  end
end
