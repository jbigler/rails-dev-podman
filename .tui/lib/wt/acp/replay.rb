# frozen_string_literal: true

module Wt
  module Acp
    # Rebuilds a session from session.jsonl ({"ts", "dir": "out"|"in"|"bridge", "msg"|"event"}),
    # starting at the last bridge `session` marker, by turning each logged line into
    # the message wt would have received live and folding it with Reducer.
    # A session/load the agent refused changes nothing, as live (Connection#loaded):
    # its marker does not start a session, and what the agent sent before refusing is dropped.
    module Replay
      Result = Data.define(:session, :session_id)

      # lines: Enumerable of NDJSON lines. → Result (session_id: the log's latest session, or nil)
      def self.call(slug, lines)
        entries = lines.filter_map { Acp.parse(it) }
        failed = failed_loads(entries)
        start = entries.each_index.reverse_each.find { marker?(entries[it]) && !failed.include?(load_id(entries[it + 1])) }
        session_id = start && entries[start]["sessionId"]
        session = AgentSession.new(slug:, session_id:, started_at: start && time(entries[start]["ts"]))
        state = { pending: {}, failed:, refused: nil } # pending: id → method of logged client requests
        messages(slug, start ? entries[(start + 1)..] : entries, state).each { session = Reducer.apply(session, it) }
        Result.new(session: Ractor.make_shareable(session), session_id:)
      end

      def self.read(slug, path)
        File.exist?(path) ? call(slug, File.foreach(path)) : call(slug, [])
      rescue SystemCallError, IOError
        call(slug, [])
      end

      def self.marker?(e) = e["dir"] == "bridge" && e["event"] == "session"

      # The id of a logged session/load request (the bridge logs it right after its marker), or nil.
      def self.load_id(e)
        msg = e && e["dir"] == "in" && e["msg"]
        msg.is_a?(Hash) && msg["method"] == "session/load" ? msg["id"] : nil
      end

      # Ids of logged session/load requests the agent answered with an error.
      def self.failed_loads(entries)
        loads = {} # id → refused?
        entries.each do |e|
          msg = e["msg"]
          if !(id = load_id(e)).nil? then loads[id] = false
          elsif e["dir"] == "out" && msg.is_a?(Hash) && !msg["method"] && loads.key?(msg["id"]) then loads[msg["id"]] = msg.key?("error")
          end
        end
        loads.select { |_, refused| refused }.keys
      end

      def self.messages(slug, entries, state)
        entries.filter_map do |e|
          msg = e["msg"]
          next unless msg.is_a?(Hash)

          at = time(e["ts"])
          case e["dir"]
          when "in" then incoming(slug, msg, at, state)
          when "out" then outgoing(slug, msg, at, state)
          end
        end
      end

      # client → agent: requests that shape the session, and answers to permission requests.
      def self.incoming(slug, msg, at, state)
        if msg["method"]
          state[:pending][msg["id"]] = msg["method"] if msg.key?("id")
          if msg["method"] == "session/load" && state[:failed].include?(msg["id"])
            state[:refused] = msg["id"]
            return
          end

          Msg::AcpSent.new(slug:, name: msg["method"], params: msg["params"], at:) if %w[session/prompt session/load].include?(msg["method"])
        elsif msg.key?("id")
          Msg::PermissionResolved.new(slug:, request_id: msg["id"])
        end
      end

      # agent → client: updates, permission requests, responses to logged client requests.
      def self.outgoing(slug, msg, at, state)
        case msg["method"]
        when "session/update"
          update = msg["params"].is_a?(Hash) && msg["params"]["update"]
          Msg::AcpUpdate.new(slug:, update:, at:) if update.is_a?(Hash) && !state[:refused]
        when "session/request_permission"
          Msg::PermissionRequested.new(slug:, request_id: msg["id"], params: msg["params"], at:)
        when nil
          state[:refused] = nil if msg["id"] == state[:refused]
          name = state[:pending].delete(msg["id"])
          in_flight = state[:pending].count { |_, m| m == "session/prompt" }
          Msg::AcpResponse.new(slug:, name:, result: msg["result"], error: msg["error"], in_flight:, at:) if name
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
