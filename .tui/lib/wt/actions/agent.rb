# frozen_string_literal: true

module Wt
  # ACP agent actions; the target is always model.focus_slug. The agent is reached
  # over its bridge socket (Acp::Send); the unit only through mise agent:up / agent:stop.
  module Actions
    # a — chat with the worktree's agent: open the chat screen, start the unit if no
    # bridge is attached, create a session if connected without one.
    def self.chat(model)
      slug = model.focus_slug
      return model unless slug

      model = model.with(ui: model.ui.with(screen: :chat, chat_slug: slug, input_focus: true, help: false, tool_index: nil))
      s = model.sessions[slug]
      case s&.connection
      when :connected then s.session_id ? model : open_session(model, slug)
      when :busy then model
      else start_agent(model, slug)
      end
    end

    # A — a new session (the transcript is replaced when the agent answers).
    def self.new_session(model)
      slug = model.focus_slug
      return model unless slug

      case model.sessions[slug]&.connection
      when :connected then open_session(model, slug)
      when :busy then model.notify("agent #{slug}: in use by another client", level: :error)
      else start_agent(model, slug)
      end
    end

    # 1 / 2 / 3 — the pending permission's options in the order the agent sent them.
    def self.answer_permission(model, key:)
      slug = model.focus_slug
      perm = model.permission_for(slug)
      return model unless perm

      n = key.to_s.delete_prefix("ctrl+").to_i
      option = perm.options[n - 1] if n.between?(1, 3)
      return model unless option

      model = Msg::PermissionResolved.new(slug:, request_id: perm.request_id).apply(model)
      [model, Acp.send_to(slug, Acp.response(perm.request_id, Acp.selected(option[:id])))]
    end

    # ⏎ in the reply input: send the text as the next prompt. A pending permission
    # is rejected first (a typed reply means "no, do this instead").
    def self.send_input(model)
      text = model.ui.input.strip
      return model if text.empty?

      slug = model.focus_slug
      s = slug && model.sessions[slug]
      unless s&.connection == :connected && s.session_id
        hint = s&.connection == :connected ? "no session, press A" : "not connected, press a"
        return model.notify("agent #{slug}: #{hint}", level: :error)
      end

      payloads = []
      if (perm = s.permission)
        reject = perm.options.find { it[:kind].start_with?("reject") } || perm.options.last
        payloads << Acp.response(perm.request_id, reject ? Acp.selected(reject[:id]) : Acp.cancelled)
        model = Msg::PermissionResolved.new(slug:, request_id: perm.request_id).apply(model)
      end
      params = Acp.prompt_params(s.session_id, text)
      payloads << Acp.request("session/prompt", params)
      model = Msg::AcpSent.new(slug:, name: "session/prompt", params: Ractor.make_shareable(params), at: model.now).apply(model)
      [model.with(ui: model.ui.with(input: "")), Acp.send_to(slug, *payloads)]
    end

    # K — confirm, then cancel a running turn and stop the agent@ unit.
    def self.stop_agent(model)
      slug = model.focus_slug
      return model unless slug

      model.with(ui: model.ui.with(confirm: Confirm.new(prompt: "Stop agent for #{slug}?", action: :confirm_stop_agent, args: [slug])))
    end

    def self.confirm_stop_agent(model, slug)
      stop = agent_task(model, "agent:stop", slug, refresh: true)
      s = model.sessions[slug]
      return [model, stop] unless s&.connection == :connected && s.session_id && (s.running || s.permission)

      # ACP: session/cancel, then answer every pending permission with "cancelled".
      payloads = [Acp.notification("session/cancel", { "sessionId" => s.session_id })]
      if (perm = s.permission)
        payloads << Acp.response(perm.request_id, Acp.cancelled)
        model = Msg::PermissionResolved.new(slug:, request_id: perm.request_id).apply(model)
      end
      [model, Rooibos::Command.batch(Acp.send_to(slug, *payloads), stop)]
    end

    # session/new in the worktree (host path = the agent's path; it is mounted there).
    def self.open_session(model, slug)
      cwd = model.worktree(slug)&.path || model.config.worktree_path(slug)
      [model, Acp.send_to(slug, Acp.request("session/new", Acp.new_session_params(cwd)))]
    end

    def self.start_agent(model, slug)
      s = model.sessions[slug] || AgentSession.new(slug:)
      model = model.put(:sessions, slug, Ractor.make_shareable(s.with(connection: :connecting, error: nil)))
      [model, agent_task(model, "agent:up", slug, refresh: false)]
    end

    # Commands.mise leaves its default cwd unfrozen, which a batch rejects as not shareable.
    def self.agent_task(model, task, slug, refresh:)
      Commands.mise(model, task, slug, task, cwd: model.config.worktree_path(slug).freeze, refresh:)
    end
  end
end
