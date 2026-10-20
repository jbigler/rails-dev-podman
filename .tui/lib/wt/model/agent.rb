# frozen_string_literal: true

module Wt
  # .container-config/status/<slug>.json. Written by claude-status-hook.sh today
  # and by acp-bridge in phase 3, which adds agent, plan and last.
  #   state: :working | :waiting | :permission | :failed | :offline
  class AgentStatus < Data.define(:state, :agent, :plan_done, :plan_total, :last, :updated_at)
    def initialize(state: :offline, agent: nil, plan_done: nil, plan_total: nil, last: nil, updated_at: nil)
      super
    end
  end

  # One entry of an ACP plan. status: :pending | :in_progress | :completed
  class PlanEntry < Data.define(:content, :status, :priority)
    def initialize(content:, status: :pending, priority: nil)
      super
    end
  end

  # One ACP tool call. kind: read | edit | delete | move | search | execute | think | fetch | other
  # status: :pending | :in_progress | :completed | :failed. locations: [{path:, line:}]
  class ToolCall < Data.define(:id, :title, :kind, :status, :locations, :diff, :output, :at)
    def initialize(id:, title: "", kind: "other", status: :pending, locations: [], diff: nil, output: nil, at: nil)
      super
    end
  end

  # A pending session/request_permission. options: [{id:, name:, kind:}] in the
  # order the agent sent them (allow once, allow always, reject).
  Permission = Data.define(:request_id, :tool_call_id, :title, :options)

  # One rendered transcript item. role: :user | :agent | :thought | :tool | :system
  class TranscriptEntry < Data.define(:role, :text, :tool_call_id, :at)
    def initialize(role:, text: "", tool_call_id: nil, at: nil)
      super
    end
  end

  # wt's view of one worktree's ACP session.
  #   connection: :disconnected | :connecting | :connected | :busy (another client holds the socket) | :ended
  #   running:    a prompt turn is in progress (set on session/prompt, cleared by its stop_reason)
  class AgentSession < Data.define(:slug, :agent, :session_id, :connection, :transcript, :plan, :tool_calls, :permission, :running, :stop_reason, :started_at, :error)
    def initialize(slug:, agent: nil, session_id: nil, connection: :disconnected, transcript: [], plan: [], tool_calls: [], permission: nil, running: false, stop_reason: nil, started_at: nil, error: nil)
      super
    end

    def plan_done = plan.count { it.status == :completed }
  end
end
