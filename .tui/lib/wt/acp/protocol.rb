# frozen_string_literal: true

module Wt
  # wt as an ACP client of the acp-bridge socket (docs/design/SPEC.md "Agent
  # container and ACP bridge"). Payloads are JSON-RPC objects with string keys;
  # Connection adds "jsonrpc" and, for requests, the id.
  module Acp
    PROTOCOL_VERSION = 1
    # Client → agent methods that are notifications (no id, no response).
    NOTIFICATIONS = %w[session/cancel].freeze
    CLIENT_CAPABILITIES = { "fs" => { "readTextFile" => false, "writeTextFile" => false }, "terminal" => false }.freeze

    def self.request(method, params) = Ractor.make_shareable({ "method" => method, "params" => params })
    def self.notification(method, params) = request(method, params)
    def self.response(id, result) = Ractor.make_shareable({ "id" => id, "result" => result })

    def self.initialize_params
      { "protocolVersion" => PROTOCOL_VERSION, "clientCapabilities" => CLIENT_CAPABILITIES,
        "clientInfo" => { "name" => "wt", "title" => "wt", "version" => "0.1.0" } }
    end

    # The worktree is mounted at its host path in agent@, so the host path is the agent's cwd too.
    def self.new_session_params(cwd) = { "cwd" => cwd, "mcpServers" => [] }
    def self.load_session_params(session_id, cwd) = { "sessionId" => session_id, "cwd" => cwd, "mcpServers" => [] }
    def self.prompt_params(session_id, text) = { "sessionId" => session_id, "prompt" => [{ "type" => "text", "text" => text }] }
    def self.selected(option_id) = { "outcome" => { "outcome" => "selected", "optionId" => option_id } }
    def self.cancelled = { "outcome" => { "outcome" => "cancelled" } }

    # Parse one NDJSON line; nil for anything that is not a JSON object.
    def self.parse(line)
      obj = JSON.parse(line)
      obj.is_a?(Hash) ? obj : nil
    rescue JSON::ParserError, EncodingError
      nil
    end
  end
end
