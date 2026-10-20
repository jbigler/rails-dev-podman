# frozen_string_literal: true

module Wt
  module Msg
    # Messages from the ACP side (Acp::Watch / Acp::Connection / Acp::Send) and the
    # session events actions fold in themselves. Every session-shaping message goes
    # through Acp::Reducer, so a live session and one replayed from session.jsonl
    # are built by the same code.
    module AcpSession
      def session_of(model) = model.sessions[slug] || AgentSession.new(slug:)
      def fold(model) = model.put(:sessions, slug, Acp::Reducer.apply(session_of(model), self))
    end

    # One `session/update` notification's `update` object (string keys, as sent).
    class AcpUpdate < Data.define(:slug, :update, :at)
      include Message
      include AcpSession

      def initialize(slug:, update:, at: nil)
        super
      end

      def apply(model)
        return model unless update.is_a?(Hash)

        before = session_of(model)
        model = fold(model)
        id = update["toolCallId"]
        return model unless id && %w[tool_call tool_call_update].include?(update["sessionUpdate"])

        was = before.tool_calls.find { it.id == id }
        now = model.sessions[slug].tool_calls.find { it.id == id }
        return model unless now&.status == :failed && was&.status != :failed

        Acp::Notify.desktop(model, "#{slug}: tool call failed", now.title)
      end
    end

    # A request wt sent to the agent that shapes the session: session/prompt (the
    # user's entry, running) and session/load (the agent replays the history).
    class AcpSent < Data.define(:slug, :name, :params, :at)
      include Message
      include AcpSession

      def initialize(slug:, name:, params: {}, at: nil)
        super
      end

      def apply(model) = fold(model)
    end

    # The response to one of wt's own requests. name: the request's method, or nil
    # when the payload was not a request (e.g. a permission answer that could not be sent).
    # error: the JSON-RPC error object ({"code", "message"}) or nil.
    # in_flight: for session/prompt, how many other prompts are still unanswered.
    class AcpResponse < Data.define(:slug, :name, :result, :error, :in_flight, :at)
      include Message
      include AcpSession

      def initialize(slug:, name:, result: nil, error: nil, in_flight: 0, at: nil)
        super
      end

      def apply(model)
        model = fold(model)
        return model unless error

        model.notify("agent #{slug}: #{name || 'send'} failed: #{Acp::Reducer.error_text(error)}", level: :error)
      end
    end

    # session/request_permission from the agent (live, or held by the bridge and re-sent on connect).
    class PermissionRequested < Data.define(:slug, :request_id, :params, :at)
      include Message
      include AcpSession

      def initialize(slug:, request_id:, params:, at: nil)
        super
      end

      def apply(model)
        repeat = model.permission_for(slug)&.request_id == request_id
        model = fold(model)
        return model if repeat

        Acp::Notify.desktop(model, "#{slug}: permission needed", model.permission_for(slug)&.title.to_s)
      end
    end

    # wt answered (or the log shows an answer to) the permission request `request_id`.
    class PermissionResolved < Data.define(:slug, :request_id)
      include Message
      include AcpSession

      def apply(model) = fold(model)
    end

    # The session rebuilt from session.jsonl on connect; replaces the old one wholesale.
    # The connection state is kept: it changes only with AcpConnection.
    class AcpReplayed < Data.define(:slug, :session)
      include Message

      def apply(model)
        previous = model.sessions[slug]
        connection = previous ? previous.connection : :disconnected
        model.put(:sessions, slug, session.with(connection:))
      end
    end

    # The socket's state changed.
    #   state: :connected (handshake done; session_id is the session to talk to, or nil)
    #          :busy (another client holds the socket; holder describes it)
    #          :ended (the bridge closed the socket after hello: its agent went away, or it was stopped)
    #          :disconnected (socket file gone, or it closed before hello and its file went with it)
    class AcpConnection < Data.define(:slug, :state, :agent, :session_id, :holder, :error)
      include Message

      BUSY = "in use by "
      ENDED = "session ended"

      def initialize(slug:, state:, agent: nil, session_id: nil, holder: nil, error: nil)
        super
      end

      def apply(model)
        s = model.sessions[slug] || AgentSession.new(slug:)
        case state
        when :connected
          wanted = s.connection == :connecting # the person pressed a / A before the agent was up
          s = s.with(connection: :connected, agent: agent || s.agent, session_id:, error:)
          model = model.put(:sessions, slug, Ractor.make_shareable(s))
          wanted && !session_id ? Actions.open_session(model, slug) : model
        when :busy
          entry = TranscriptEntry.new(role: :system, text: "#{BUSY}#{holder}", at: model.now)
          transcript = s.transcript.reject { it.role == :system && it.text.start_with?(BUSY) } + [entry]
          model.put(:sessions, slug, Ractor.make_shareable(s.with(connection: :busy, transcript:)))
        else
          s = s.with(connection: state, running: false, permission: nil)
          if state == :ended && s.transcript.last&.text != ENDED
            s = s.with(transcript: [*s.transcript, TranscriptEntry.new(role: :system, text: ENDED, at: model.now)])
          end
          model.put(:sessions, slug, Ractor.make_shareable(s))
        end
      end
    end

    # `mise run agent:up` finished (Acp::Up), reported like any mise task. A failure
    # also ends the "connecting…" that a / A started, with the reason; on success the
    # session stays :connecting until Watch connects, which then opens the session.
    class AgentUpFinished < Data.define(:slug, :status, :stderr)
      include Message

      def apply(model)
        finished = CommandFinished.new(label: "agent:up", slug:, status:, stderr:, refresh: false)
        model, cmd = finished.apply(model)
        s = model.sessions[slug]
        if status != 0 && s&.connection == :connecting
          s = s.with(connection: :disconnected, error: "agent:up failed: #{finished.stderr_line}")
          model = model.put(:sessions, slug, Ractor.make_shareable(s))
        end
        [model, cmd]
      end
    end
  end
end
