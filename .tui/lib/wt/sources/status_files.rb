# frozen_string_literal: true

require "json"
require "time"

module Wt
  module Sources
    # .container-config/status/<slug>.json, written by claude-status-hook.sh or
    # (phase 3) acp-bridge. A broken file only drops that slug.
    module StatusFiles
      STATES = %i[working waiting permission failed offline].freeze

      def self.fetch(config)
        statuses = Dir.glob(File.join(config.status_dir, "*.json")).sort.filter_map do |path|
          next if File.basename(path).start_with?(".")

          status = begin
            parse(File.read(path))
          rescue SystemCallError, IOError
            nil
          end
          status && [File.basename(path, ".json"), status]
        end.to_h
        Msg::StatusFiles.new(statuses: Ractor.make_shareable(statuses))
      end

      # JSON text → AgentStatus, or nil when it is not a JSON object.
      def self.parse(text)
        data = JSON.parse(text)
        return nil unless data.is_a?(Hash)

        state = STATES.find { it.to_s == data["state"] } || :offline
        plan = data["plan"].is_a?(Hash) ? data["plan"] : {}
        AgentStatus.new(
          state:,
          # Only the bridge writes "agent"; the other writer, claude-status-hook.sh,
          # runs inside Claude Code, so a file without it is Claude's.
          agent: string(data["agent"]) || "claude",
          plan_done: int(plan["done"]),
          plan_total: int(plan["total"]),
          last: string(data["last"]),
          updated_at: time(data["ts"])
        )
      rescue JSON::ParserError
        nil
      end

      def self.string(v) = v.is_a?(String) && !v.empty? ? v : nil
      def self.int(v) = v.is_a?(Integer) ? v : nil

      def self.time(v)
        v.is_a?(String) ? Time.iso8601(v) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
