# frozen_string_literal: true

require "securerandom"
require "socket"

module Wt
  module Acp
    # One attached client session on a bridge socket, driven by `run` on its own
    # thread (Watch starts it). Handshake: hello (or busy) → replay session.jsonl →
    # initialize → reuse hello.sessionId, else session/load the log's session when
    # the agent supports it, else wait for the person (a / A). Afterwards it relays
    # agent traffic as messages. Malformed lines are skipped, never fatal.
    class Connection
      attr_reader :slug, :outcome

      READ_CHUNK = 65_536

      # outcome after run: :busy | :ended | :canceled
      def initialize(slug:, socket:, config:, out:, cwd: nil)
        @slug = slug
        @socket = socket
        @config = config
        @out = out
        @cwd = cwd || config.worktree_path(slug)
        @write_lock = Mutex.new
        @prefix = "wt-#{SecureRandom.hex(4)}-"
        @counter = 0
        @pending = {} # id → method, for wt's own requests
        @hello = nil
        @log_session_id = nil
        @outcome = nil
      end

      # Send one payload; requests get an id. → true if written.
      def deliver(payload)
        msg = { "jsonrpc" => "2.0" }.merge(payload)
        method = payload["method"]
        if method && !payload.key?("id") && !NOTIFICATIONS.include?(method)
          id = @write_lock.synchronize { "#{@prefix}#{@counter += 1}" }
          @write_lock.synchronize { @pending[id] = method }
          msg["id"] = id
        end
        write(msg)
      end

      def request(method, params) = deliver({ "method" => method, "params" => params })

      def write(msg)
        line = "#{JSON.generate(msg)}\n"
        @write_lock.synchronize { @socket.write(line) }
        true
      rescue IOError, SystemCallError
        false
      end

      def close
        @socket.close unless @socket.closed?
      rescue IOError
        nil
      end

      def run(token)
        buffer = String.new(encoding: Encoding::BINARY)
        until token.canceled?
          ready = IO.select([@socket], nil, nil, 0.2)
          next unless ready

          chunk = @socket.read_nonblock(READ_CHUNK, exception: false)
          next if chunk == :wait_readable
          break if chunk.nil?

          buffer << chunk
          while (nl = buffer.index("\n"))
            line = buffer.slice!(0..nl)
            handle(line) unless line.strip.empty?
          end
        end
        @outcome = token.canceled? ? :canceled : (@outcome || :ended)
      rescue IOError, SystemCallError
        @outcome = token.canceled? ? :canceled : (@outcome || :ended)
      ensure
        Registry.unregister(slug, self)
        close
      end

      def handle(line)
        msg = Acp.parse(line.force_encoding(Encoding::UTF_8).scrub)
        return unless msg

        method = msg["method"]
        if method&.start_with?("_bridge/") then bridge(method, msg["params"].is_a?(Hash) ? msg["params"] : {})
        elsif method && msg.key?("id") then agent_request(msg)
        elsif method then notification(msg)
        elsif msg.key?("id") then response(msg)
        end
      rescue StandardError => e
        warn "wt acp #{slug}: #{e.class}: #{e.message}" if $DEBUG
      end

      private

      def put(msg) = @out.put(Ractor.make_shareable(msg))

      def bridge(method, params)
        case method
        when "_bridge/hello"
          @hello = params
          replay = Replay.read(slug, @config.session_log(slug))
          @log_session_id = replay.session_id
          session = replay.session.with(agent: params["agent"])
          # Held requests are re-sent right after hello; a logged one the bridge no longer holds is stale.
          session = session.with(permission: nil) unless params["pending"].to_i.positive?
          put(Msg::AcpReplayed.new(slug:, session:))
          Registry.register(slug, self)
          request("initialize", Acp.initialize_params)
        when "_bridge/busy"
          @outcome = :busy
          put(Msg::AcpConnection.new(slug:, state: :busy, holder: params["holder"].to_s))
        end
      end

      def agent_request(msg)
        if msg["method"] == "session/request_permission"
          put(Msg::PermissionRequested.new(slug:, request_id: msg["id"], params: msg["params"] || {}, at: Time.now))
        else
          write({ "jsonrpc" => "2.0", "id" => msg["id"], "error" => { "code" => -32_601, "message" => "Method not found: #{msg['method']}" } })
        end
      end

      def notification(msg)
        return unless msg["method"] == "session/update" && msg["params"].is_a?(Hash)

        put(Msg::AcpUpdate.new(slug:, update: msg["params"]["update"], at: Time.now))
      end

      def response(msg)
        method = @write_lock.synchronize { @pending.delete(msg["id"]) }
        case method
        when nil then nil
        when "initialize" then initialized(msg)
        when "session/load"
          put(Msg::AcpResponse.new(slug:, name: method, result: msg["result"], error: msg["error"], at: Time.now))
          connected(msg["error"] ? nil : @load_id)
        else put(Msg::AcpResponse.new(slug:, name: method, result: msg["result"], error: msg["error"], at: Time.now))
        end
      end

      def initialized(msg)
        return connected(nil, error: "initialize failed: #{Reducer.error_text(msg['error'])}") if msg["error"]

        result = msg["result"].is_a?(Hash) ? msg["result"] : {}
        if (sid = @hello["sessionId"])
          connected(sid)
        elsif @log_session_id && result.dig("agentCapabilities", "loadSession")
          @load_id = @log_session_id
          params = Acp.load_session_params(@load_id, @cwd)
          put(Msg::AcpSent.new(slug:, name: "session/load", params:, at: Time.now))
          request("session/load", params)
        else
          connected(nil)
        end
      end

      def connected(session_id, error: nil)
        put(Msg::AcpConnection.new(slug:, state: :connected, agent: @hello && @hello["agent"], session_id:, error:))
      end
    end
  end
end
