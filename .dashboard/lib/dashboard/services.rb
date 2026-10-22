# frozen_string_literal: true

module Dashboard
  # §5.2 service state mapping and the SVC summary glyph.
  module Services
    # unit: systemctl props or nil; ctr: Container or nil.
    def self.state(unit, ctr)
      active = unit&.fetch("ActiveState", nil)
      return :failed if active == "failed" || (ctr && ctr.state == "exited" && ctr.exit_code != 0) || ctr&.health == "unhealthy"
      return :starting if active == "activating" || (ctr&.running? && ctr.health == "starting")
      return :up if ctr&.running?

      :stopped
    end

    # → [Service] in display order, or UNKNOWN when podman or systemd could not be read.
    def self.for(ws, name, env, units, containers)
      return UNKNOWN if units == UNKNOWN || containers == UNKNOWN

      Workspace::SERVICES.map do |label, svc|
        unit = ws.unit(svc, name)
        ctr = containers[ws.container(name, svc)]
        port = Workspace::PORT_KEYS[svc]&.then { env[it] }
        Service.new(label:, unit:, state: state(units[unit], ctr), port: port && !port.empty? ? port : nil, health: ctr&.health)
      end
    end

    def self.summary(services)
      return :unknown if services == UNKNOWN

      states = services.map(&:state)
      %i[failed starting up].find { states.include?(it) } || :stopped
    end
  end
end
