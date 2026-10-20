# frozen_string_literal: true

module Wt
  module Acp
    # Rebuilds a session from session.jsonl ({"ts", "dir": "out"|"in"|"bridge", "msg"|"event"}),
    # starting at the last bridge `session` marker, by turning each logged line into
    # the message wt would have received live and folding it with Reducer.
    module Replay
      Result = Data.define(:session, :session_id)

      # lines: Enumerable of NDJSON lines. → Result (session_id: the log's latest session, or nil)
      def self.call(slug, lines)
        entries = lines.filter_map { Acp.parse(it) }
        start = entries.rindex { it["dir"] == "bridge" && it["event"] == "session" }
        session_id = start && entries[start]["sessionId"]
        session = AgentSession.new(slug:, session_id:, started_at: start && time(entries[start]["ts"]))
        pending = {} # id → method of logged client requests, to name their responses
        messages(slug, start ? entries[(start + 1)..] : entries, pending).each { session = Reducer.apply(session, it) }
        Result.new(session: Ractor.make_shareable(session), session_id:)
      end

      def self.read(slug, path)
        File.exist?(path) ? call(slug, File.foreach(path)) : call(slug, [])
      rescue SystemCallError, IOError
        call(slug, [])
      end

      def self.messages(slug, entries, pending)
        entries.filter_map do |e|
          msg = e["msg"]
          next unless msg.is_a?(Hash)

          at = time(e["ts"])
          case e["dir"]
          when "in" then incoming(slug, msg, at, pending)
          when "out" then outgoing(slug, msg, at, pending)
          end
        end
      end

      # client → agent: requests that shape the session, and answers to permission requests.
      def self.incoming(slug, msg, at, pending)
        if msg["method"]
          pending[msg["id"]] = msg["method"] if msg.key?("id")
          Msg::AcpSent.new(slug:, name: msg["method"], params: msg["params"], at:) if %w[session/prompt session/load].include?(msg["method"])
        elsif msg.key?("id")
          Msg::PermissionResolved.new(slug:, request_id: msg["id"])
        end
      end

      # agent → client: updates, permission requests, responses to logged client requests.
      def self.outgoing(slug, msg, at, pending)
        case msg["method"]
        when "session/update"
          Msg::AcpUpdate.new(slug:, update: msg.dig("params", "update"), at:) if msg["params"].is_a?(Hash)
        when "session/request_permission"
          Msg::PermissionRequested.new(slug:, request_id: msg["id"], params: msg["params"], at:)
        when nil
          name = pending.delete(msg["id"])
          Msg::AcpResponse.new(slug:, name:, result: msg["result"], error: msg["error"], at:) if name
        end
      end

      def self.time(ts)
        ts.is_a?(String) ? Time.iso8601(ts) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
