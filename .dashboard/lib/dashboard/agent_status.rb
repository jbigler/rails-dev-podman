# frozen_string_literal: true

module Dashboard
  # §7.2: the claude container plus the status file → Agent.
  module AgentStatus
    PHASES = { "permission" => :permission, "question" => :question, "working" => :working, "done" => :done,
               "idle" => :idle, "offline" => :off }.freeze
    V1 = { "working" => :working, "waiting" => :done, "offline" => :off }.freeze

    # ctr: the <P>-<W>-claude Container (nil when absent, UNKNOWN when podman failed); file: StatusFile or nil.
    def self.derive(ctr, file)
      return UNKNOWN if ctr == UNKNOWN
      return Agent.of(:off) unless ctr&.running?
      return Agent.of(:working) unless file
      return Agent.of(:idle, since: file.ts) if file.ts && ctr.started_at && file.ts < ctr.started_at

      if file.v == 2
        Agent.of(PHASES.fetch(file.phase.to_s, :idle), since: file.ts, message: file.message, tool: file.tool, last_message: file.last_message)
      else
        Agent.of(V1.fetch(file.state.to_s, :idle), since: file.ts)
      end
    end

    # "12s", "4m", "2h", "3d"
    def self.age(since, now)
      s = [(now - since).to_i, 0].max
      if s < 60 then "#{s}s"
      elsif s < 3600 then "#{s / 60}m"
      elsif s < 86_400 then "#{s / 3600}h"
      else "#{s / 86_400}d"
      end
    end
  end
end
