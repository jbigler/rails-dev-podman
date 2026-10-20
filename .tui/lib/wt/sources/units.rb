# frozen_string_literal: true

module Wt
  module Sources
    # Every worktree's services in two calls, the same two views `mise run status`
    # (cmd_status in .scripts/podman-wt.sh) prints: the systemd units and the
    # `<prefix>-<slug>-*` containers.
    #
    # Merge rule, first match wins (unit = <prefix>-<svc>@<slug>.service, container
    # = <prefix>-<slug>-<svc>):
    #   1. unit ActiveState failed                       → :failed   (detail: unit Result)
    #   2. container exited with a non-zero code         → :exited   (detail: "exited <code>")
    #   3. unit activating, or container health starting → :starting
    #   4. container running and healthy                 → :healthy
    #   5. container running (unhealthy: detail)         → :running
    #   6. anything else                                 → :stopped
    # port is the host port published for the service's main container port (first
    # published one otherwise) and started_at the container's start time (the unit's
    # ActiveEnterTimestamp when podman has none); both only while the service is up
    # or starting.
    module Units
      PROPERTIES = "Id,ActiveState,SubState,Result,ActiveEnterTimestamp"
      # The container port each service is reached on; rails also publishes its debug port.
      MAIN_PORT = { "rails" => 3000, "db" => 5432, "rustfs" => 9000, "playwright" => 8888 }.freeze

      def self.fetch(config, slugs)
        ps = run(["podman", "ps", "-a", "--format", "json", "--filter", "name=^#{config.prefix}-"], config)
        units = slugs.flat_map { |slug| Service::NAMES.map { config.unit_name(it, slug) } }
        show = units.empty? ? "" : run(["systemctl", "--user", "show", *units, "--property=#{PROPERTIES}"], config)
        Msg::UnitsChanged.new(services: parse(ps, show, prefix: config.prefix, slugs:))
      end

      # A missing podman / systemctl or a failing call raises, so Commands::Fetch
      # reports SourceFailed and the cell shows `?`.
      def self.run(argv, config)
        r = Shell.capture(argv, timeout: config.timeout)
        raise Error, "#{argv.first}: #{r.error_line}" unless r.ok?

        r.stdout
      end

      # ps_json: `podman ps -a --format json`; show_text: `systemctl show` for many units.
      # → slug => [Service] in Service::NAMES order, for exactly `slugs`.
      def self.parse(ps_json, show_text, prefix:, slugs:)
        containers = (ps_json.strip.empty? ? [] : JSON.parse(ps_json)).to_h { [Array(it["Names"]).first, it] }
        units = parse_show(show_text)
        slugs.to_h do |slug|
          [slug, Service::NAMES.map do |svc|
            unit = "#{prefix}-#{svc}@#{slug}.service"
            merge(svc, unit, units[unit] || {}, containers["#{prefix}-#{slug}-#{svc}"])
          end]
        end
      end

      # `systemctl show A B C` prints one blank-line separated block per unit.
      def self.parse_show(text)
        text.split(/\n[ \t]*\n/).filter_map do |block|
          props = block.lines.to_h { it.chomp.split("=", 2) }.reject { |k, _| k.nil? || k.empty? }
          props["Id"] && [props["Id"], props]
        end.to_h
      end

      def self.merge(svc, unit, props, ctr)
        active = props["ActiveState"]
        running = ctr && ctr["State"] == "running"
        health = health(ctr)
        state, detail =
          if active == "failed" then [:failed, props["Result"]]
          elsif ctr && ctr["State"] == "exited" && ctr["ExitCode"].to_i != 0 then [:exited, "exited #{ctr['ExitCode']}"]
          elsif active == "activating" || (running && health == "starting") then [:starting, nil]
          elsif running && health == "healthy" then [:healthy, nil]
          elsif running then [:running, health == "unhealthy" ? "unhealthy" : nil]
          else [:stopped, nil]
          end
        live = %i[running healthy starting].include?(state)
        Service.new(name: svc, unit:, state:, detail:,
                    port: (port(svc, ctr) if live && running),
                    started_at: (started_at(ctr, props) if live))
      end

      # podman ps JSON carries the health check result in Status ("healthy",
      # "starting", "unhealthy" or ""); match the word so a human-readable
      # "Up 2 hours (healthy)" also works.
      def self.health(ctr)
        ctr && ctr["Status"].to_s.downcase[/\b(unhealthy|healthy|starting)\b/, 1]
      end

      def self.port(svc, ctr)
        published = Array(ctr["Ports"]).select { it["host_port"].to_i.positive? }
        main = published.find { it["container_port"].to_i == MAIN_PORT[svc] }
        (main || published.first)&.dig("host_port")&.to_i
      end

      def self.started_at(ctr, props)
        t = ctr && ctr["StartedAt"].to_i
        return Time.at(t) if t&.positive?

        unit_time(props["ActiveEnterTimestamp"]) if props["ActiveState"] == "active"
      end

      # "Tue 2026-10-20 07:12:33 CEST", or "@1792480353" under --timestamp=unix; empty
      # when the unit never entered active.
      def self.unit_time(value)
        return nil if value.nil? || value.strip.empty? || value == "n/a"
        return Time.at(value[1..].to_i) if value.start_with?("@")

        Time.parse(value)
      rescue ArgumentError
        nil
      end
    end
  end
end
