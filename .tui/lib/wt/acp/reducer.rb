# frozen_string_literal: true

module Wt
  module Acp
    # Pure fold of ACP events into an AgentSession. Live messages and the
    # session.jsonl replay both go through `apply`, so they cannot disagree.
    # Inputs carry the protocol's own JSON (string keys); outputs are model values.
    module Reducer
      TOOL_STATUSES = { "pending" => :pending, "in_progress" => :in_progress, "completed" => :completed, "failed" => :failed }.freeze
      PLAN_STATUSES = { "pending" => :pending, "in_progress" => :in_progress, "completed" => :completed }.freeze
      PRIORITIES = { "high" => :high, "medium" => :medium, "low" => :low }.freeze
      CHUNK_ROLES = { "user_message_chunk" => :user, "agent_message_chunk" => :agent, "agent_thought_chunk" => :thought }.freeze

      # session: AgentSession; message: Msg::AcpUpdate | AcpSent | AcpResponse |
      # PermissionRequested | PermissionResolved (anything else leaves it unchanged).
      def self.apply(session, message)
        s = case message
            when Msg::AcpUpdate then update(session, message.update, message.at)
            when Msg::AcpSent then sent(session, message)
            when Msg::AcpResponse then response(session, message)
            when Msg::PermissionRequested then permission(session, message)
            when Msg::PermissionResolved
              session.permission&.request_id == message.request_id ? session.with(permission: nil) : session
            else session
            end
        Ractor.make_shareable(s)
      end

      def self.update(s, u, at)
        return s unless u.is_a?(Hash)

        s = s.with(started_at: at) if s.started_at.nil? && at
        kind = u["sessionUpdate"]
        if (role = CHUNK_ROLES[kind]) then chunk(s, role, content_text(u["content"]), at)
        elsif kind == "tool_call" || kind == "tool_call_update" then tool_call(s, u, at)
        elsif kind == "plan" then s.with(plan: plan_entries(u["entries"]))
        else s # available_commands_update, current_mode_update, anything newer
        end
      end

      # Consecutive chunks of one role are one transcript entry.
      def self.chunk(s, role, text, at)
        return s if text.empty?

        last = s.transcript.last
        if last && last.role == role && last.tool_call_id.nil?
          s.with(transcript: [*s.transcript[0...-1], last.with(text: last.text + text)])
        else
          s.with(transcript: [*s.transcript, TranscriptEntry.new(role:, text:, at:)])
        end
      end

      # tool_call creates (or, if already known, updates); tool_call_update merges the
      # fields present. A call first seen also gets its transcript entry.
      def self.tool_call(s, u, at)
        id = u["toolCallId"]
        return s unless id.is_a?(String) && !id.empty?

        existing = s.tool_calls.find { it.id == id }
        call = merge_tool_call(existing || ToolCall.new(id:, at:), u)
        if existing
          s.with(tool_calls: s.tool_calls.map { it.id == id ? call : it })
        else
          s.with(tool_calls: [*s.tool_calls, call],
                 transcript: [*s.transcript, TranscriptEntry.new(role: :tool, text: call.title, tool_call_id: id, at:)])
        end
      end

      def self.merge_tool_call(call, u)
        changes = {}
        changes[:title] = u["title"].to_s if u.key?("title") && u["title"]
        changes[:kind] = u["kind"].to_s if u["kind"]
        changes[:status] = TOOL_STATUSES.fetch(u["status"], call.status) if u["status"]
        changes[:locations] = locations(u["locations"]) if u.key?("locations")
        if u.key?("content")
          content = u["content"].is_a?(Array) ? u["content"].grep(Hash) : []
          diffs = content.select { it["type"] == "diff" }.map { { path: it["path"], old_text: it["oldText"], new_text: it["newText"].to_s } }
          texts = content.select { it["type"] == "content" }.map { content_text(it["content"]) }.reject(&:empty?)
          changes[:diff] = diffs.size > 1 ? diffs : diffs.first
          changes[:output] = texts.empty? ? nil : texts.join("\n")
        end
        call.with(**changes)
      end

      def self.locations(list)
        return [] unless list.is_a?(Array)

        list.grep(Hash).filter_map { |l| l["path"].is_a?(String) && { path: l["path"], line: l["line"].is_a?(Integer) ? l["line"] : nil } }
      end

      def self.plan_entries(list)
        return [] unless list.is_a?(Array)

        list.grep(Hash).map do |e|
          PlanEntry.new(content: e["content"].to_s, status: PLAN_STATUSES.fetch(e["status"], :pending), priority: PRIORITIES[e["priority"]])
        end
      end

      # A ContentBlock as text: text blocks verbatim, links and resources by name.
      def self.content_text(block)
        return "" unless block.is_a?(Hash)

        case block["type"]
        when "text" then block["text"].to_s
        when "resource_link" then "[#{block['name'] || block['uri']}]"
        when "resource" then "[#{block.dig('resource', 'uri')}]"
        when "image" then "[image]"
        else ""
        end
      end

      def self.sent(s, m)
        params = m.params.is_a?(Hash) ? m.params : {}
        case m.name
        when "session/prompt"
          text = Array(params["prompt"]).map { content_text(it) }.join
          s.with(transcript: [*s.transcript, TranscriptEntry.new(role: :user, text:, at: m.at)],
                 running: true, stop_reason: nil, error: nil, started_at: s.started_at || m.at)
        when "session/load"
          # The agent replays the whole conversation as session/update notifications.
          s.with(session_id: params["sessionId"], transcript: [], plan: [], tool_calls: [], permission: nil,
                 running: false, stop_reason: nil, error: nil)
        else s
        end
      end

      def self.response(s, m)
        result = m.result.is_a?(Hash) ? m.result : {}
        case m.name
        when "session/new"
          return s.with(error: error_text(m.error)) if m.error

          AgentSession.new(slug: s.slug, agent: s.agent, connection: s.connection, session_id: result["sessionId"], started_at: m.at)
        when "session/load"
          m.error ? s.with(session_id: nil, error: error_text(m.error)) : s
        when "session/prompt"
          if m.error
            text = error_text(m.error)
            s.with(running: false, error: text, transcript: [*s.transcript, TranscriptEntry.new(role: :system, text: "error: #{text}", at: m.at)])
          else
            s.with(running: false, stop_reason: result["stopReason"]&.to_s)
          end
        else s
        end
      end

      def self.permission(s, m)
        params = m.params.is_a?(Hash) ? m.params : {}
        tc = params["toolCall"].is_a?(Hash) ? params["toolCall"] : {}
        s = tool_call(s, tc, m.at) if tc["toolCallId"]
        id = tc["toolCallId"]
        title = tc["title"] || s.tool_calls.find { it.id == id }&.title
        options = Array(params["options"]).grep(Hash).map { { id: it["optionId"].to_s, name: it["name"].to_s, kind: it["kind"].to_s } }
        s.with(permission: Permission.new(request_id: m.request_id, tool_call_id: id, title: title.to_s.empty? ? "permission requested" : title.to_s, options:))
      end

      def self.error_text(error)
        return error.to_s unless error.is_a?(Hash)

        error["message"].to_s.empty? ? "error #{error['code']}" : error["message"].to_s
      end
    end
  end
end
