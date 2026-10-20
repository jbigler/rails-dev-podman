# frozen_string_literal: true

module Wt
  module Acp
    # Process-global slug → live Connection map. Watch registers a connection once
    # the bridge said hello; commands (Acp::Send) write through it. Thread-safe.
    module Registry
      @mutex = Mutex.new
      @connections = {}

      def self.register(slug, connection) = @mutex.synchronize { @connections[slug] = connection }

      # Only removes `connection` itself, so a stale thread cannot drop its successor.
      def self.unregister(slug, connection)
        @mutex.synchronize { @connections.delete(slug) if @connections[slug].equal?(connection) }
      end

      def self.[](slug) = @mutex.synchronize { @connections[slug] }
      def self.clear = @mutex.synchronize { @connections.clear }
    end

    # Writes payloads (in order) to a worktree's agent. Requests get a wt id and
    # their response comes back as Msg::AcpResponse. Not connected → AcpResponse
    # with an error, so the person sees why nothing happened.
    class Send < Data.define(:slug, :payload)
      include Rooibos::Command::Custom

      def call(out, _token)
        payloads = payload.is_a?(Array) ? payload : [payload]
        connection = Registry[slug]
        payloads.each do |p|
          next if connection&.deliver(p)

          error = { "code" => -32_000, "message" => "agent not connected" }
          out.put(Ractor.make_shareable(Msg::AcpResponse.new(slug:, name: p["id"] ? nil : p["method"], error:, at: Time.now)))
          break
        end
      end
    end

    def self.send_to(slug, *payloads) = Send.new(slug:, payload: Ractor.make_shareable(payloads.size == 1 ? payloads.first : payloads))
  end
end
