# frozen_string_literal: true

module Wt
  module Views
    # One worktree's agent, as drawn by the dashboard agent panel, the Agents
    # screen and the chat: title, plan, tool calls, permission box, reply input.
    # ACP session first; without one, the status file (phase 1).
    module Session
      W = Widgets
      STATUS_GLYPHS = { pending: "◐", in_progress: "●", completed: "✓", failed: "✗" }.freeze
      STATUS_LABELS = { pending: "pending", in_progress: "running", completed: "done", failed: "failed" }.freeze
      PLAN_MARKS = { completed: "[x]", in_progress: "[~]", pending: "[ ]" }.freeze
      FILE_STATES = { working: "working", waiting: "waiting for you", permission: "needs permission",
                      failed: "failed", offline: "offline" }.freeze
      PLAN_WIDTH = 36

      module_function

      # The ACP session when one is (or was) connected, else nil.
      def live(model, slug)
        s = slug && model.sessions[slug]
        s if s && s.connection != :disconnected
      end

      def agent_name(model, slug) = model.sessions[slug]&.agent || model.agents[slug]&.agent

      # [Span]: "Agent claude-agent-acp · session 15m · ● running"; unknown parts omitted.
      def title(model, tui, theme, slug)
        spans = [W.span(tui, theme, "Agent", :tx, bold: true)]
        name = agent_name(model, slug)
        spans << W.span(tui, theme, " #{name}", :tx2) if name
        s = live(model, slug)
        if s
          spans << W.span(tui, theme, " · session #{W.duration(model.now - s.started_at)}", :tx2) if s.started_at.is_a?(Time)
          turns = s.transcript.count { it.role == :user }
          spans << W.span(tui, theme, " · #{turns} turn#{'s' unless turns == 1}", :tx2) if turns.positive?
        end
        state = model.agent_state(slug)
        spans << W.span(tui, theme, " · ", :tx2) << W.glyph(tui, theme, state, state_label(model, slug)) if state
        spans
      end

      # Short state word for a worktree's agent ("running", "needs input", "waiting").
      def state_label(model, slug)
        if live(model, slug)
          case model.agent_state(slug)
          when :permission then "needs input"
          when :failed then "failed"
          when :running then "running"
          when :offline then "ended"
          else "idle"
          end
        else
          FILE_STATES.fetch(model.agents[slug]&.state, "offline")
        end
      end

      # Plan progress as [done, total], session plan first, status file second.
      def plan_progress(model, slug)
        s = model.sessions[slug]
        return [s.plan_done, s.plan.size] if s && !s.plan.empty?

        st = model.agents[slug]
        [st.plan_done, st.plan_total] if st&.plan_total
      end

      # "▰▰▰▱▱" scaled to at most `cells`.
      def bar(done, total, cells = 8)
        return "" unless total&.positive?

        n = [total, cells].min
        filled = (done.to_f / total * n).round
        ("▰" * filled) + ("▱" * (n - filled))
      end

      # Dashboard agent panel content (no border).
      def panel(model, tui, theme, slug, rows: 12)
        s = live(model, slug)
        return offline_panel(model, tui, theme, slug) unless s

        perm = model.permission_for(slug)
        top = tui.layout(direction: :horizontal, constraints: [tui.constraint_length(PLAN_WIDTH), tui.constraint_fill(1)], children: [
          tui.paragraph(text: plan_lines(tui, theme, s)),
          tui.paragraph(text: tool_lines(model, tui, theme, s, rows:))
        ])
        parts = [[tui.constraint_fill(1), top],
                 [tui.constraint_length(1), tui.paragraph(text: [latest_message(tui, theme, s)])]]
        parts << [tui.constraint_length(4), permission_box(model, tui, theme, slug)] if perm
        parts << [tui.constraint_length(2), input_row(model, tui, theme, slug, hint: "⏎ send · a full chat")]
        tui.layout(direction: :vertical, constraints: parts.map(&:first), children: parts.map(&:last))
      end

      def offline_panel(model, tui, theme, slug)
        st = model.agents[slug]
        s = model.sessions[slug]
        lines = []
        if model.failed?("status", slug) || model.failed?("status_files", slug)
          lines << W.line(tui, W.unknown(tui, theme), W.span(tui, theme, " status unknown", :tx2))
        elsif st
          state = st.state
          lines << W.line(tui, W.glyph(tui, theme, state, FILE_STATES.fetch(state, state.to_s)),
                          (W.span(tui, theme, "  #{st.agent}", :tx2) if st.agent),
                          (W.span(tui, theme, "  updated #{W.duration(model.now - st.updated_at)} ago", :tx2) if st.updated_at.is_a?(Time)))
          if (pp = plan_progress(model, slug))
            lines << W.line(tui, W.span(tui, theme, "plan ", :tx2), W.span(tui, theme, bar(*pp), :ac), W.span(tui, theme, " #{pp[0]} of #{pp[1]}", :tx2))
          end
          lines << W.line(tui, W.span(tui, theme, W.truncate(st.last, 200), :tx)) if st.last
        else
          lines << W.line(tui, W.glyph(tui, theme, :offline, "no agent"))
        end
        lines << W.line(tui, W.span(tui, theme, "connecting…", :tx2)) if s&.connection == :connecting
        lines << W.line(tui)
        lines << W.line(tui, *W.key_hint(tui, theme, "a", "start a chat"))
        tui.paragraph(text: lines)
      end

      def plan_lines(tui, theme, s)
        return [W.line(tui, W.span(tui, theme, "no plan yet", :tx2))] if s.plan.empty?

        [W.line(tui, W.span(tui, theme, "plan", :tx, bold: true), W.span(tui, theme, " · #{s.plan_done} of #{s.plan.size}", :tx2)),
         *s.plan.map { plan_entry(tui, theme, it, PLAN_WIDTH - 5) }]
      end

      def plan_entry(tui, theme, entry, width)
        color = { completed: :grn, in_progress: :yel }.fetch(entry.status, :tx2)
        W.line(tui, W.span(tui, theme, PLAN_MARKS.fetch(entry.status, "[ ]"), color),
               W.span(tui, theme, " #{W.truncate(entry.content, width)}", entry.status == :completed ? :tx2 : :tx))
      end

      # Tool call rows, newest last; the window follows the selection (or the tail).
      def tool_lines(model, tui, theme, s, rows: 12)
        calls = s.tool_calls
        idx = model.ui.tool_index
        follow = idx.nil?
        header = W.line(tui, W.span(tui, theme, "tool calls", :tx, bold: true),
                        W.span(tui, theme, " · #{calls.size}", :tx2),
                        (W.span(tui, theme, " · follow ●", :ac) if follow))
        return [header, W.line(tui, W.span(tui, theme, "none yet", :tx2))] if calls.empty?

        visible = [rows - 1, 1].max
        last = follow ? calls.size - 1 : [idx, calls.size - 1].min
        first = [last - visible + 1, 0].max
        [header, *calls[first..last].each_with_index.map { |c, i| tool_row(tui, theme, c, selected: !follow && first + i == idx) }]
      end

      def location(c)
        loc = c.locations.first
        return unless loc

        path = loc[:path] || loc["path"]
        line = loc[:line] || loc["line"]
        line ? "#{path}:#{line}" : path
      end

      def kind_spans(tui, theme, kind)
        kind = kind.to_s
        [W.span(tui, theme, Theme::KIND_GLYPHS.fetch(kind, "·"), theme.kind_color(kind)), W.span(tui, theme, " #{kind.ljust(8)}", :tx2)]
      end

      def status_span(tui, theme, status)
        W.span(tui, theme, "#{STATUS_GLYPHS.fetch(status, '?')} #{STATUS_LABELS.fetch(status, status.to_s)}", theme.state_color(status))
      end

      def tool_row(tui, theme, c, selected: false, width: 70)
        at = c.at.is_a?(Time) ? c.at.strftime("%H:%M") : "     "
        what = [c.title, location(c)].compact.reject(&:empty?).uniq.join("  ")
        spans = [W.span(tui, theme, "#{at}  ", :tx2), *kind_spans(tui, theme, c.kind),
                 W.span(tui, theme, W.pad(what, width), :tx), W.span(tui, theme, " "), status_span(tui, theme, c.status)]
        spans << W.span(tui, theme, "  o nvim · d diff", :ac) if selected
        return W.line(tui, spans) unless selected

        tui.line(spans: spans, style: theme.style(:tx, bg: :sel))
      end

      def latest_message(tui, theme, s)
        msg = s.transcript.reverse.find { it.role == :agent }
        return W.line(tui, W.span(tui, theme, "—", :tx2)) unless msg

        W.line(tui, W.span(tui, theme, "◇ ", :cyn), W.span(tui, theme, W.truncate(msg.text.to_s.lines.first&.chomp, 240), :tx))
      end

      # Number chips for a permission's options, in the order the agent sent them.
      def permission_options(tui, theme, perm)
        perm.options.first(3).each_with_index.flat_map do |opt, i|
          name = opt[:name] || opt["name"]
          kind = (opt[:kind] || opt["kind"]).to_s
          chip = kind.start_with?("reject") ? :red : (kind.end_with?("always") ? :yel : :grn)
          [tui.span(content: " #{i + 1} ", style: theme.style(:bg, bg: chip, bold: true)),
           W.span(tui, theme, " #{name}  ", :tx)]
        end
      end

      # The bordered "◆ Permission <title>" box with its 1–3 options.
      def permission_box(model, tui, theme, slug, reply_hint: true)
        perm = model.permission_for(slug)
        call = model.sessions[slug]&.tool_calls&.find { it.id == perm.tool_call_id }
        lines = []
        lines << W.line(tui, *kind_spans(tui, theme, call.kind), W.span(tui, theme, [call.title, location(call)].compact.uniq.join("  "), :tx)) if call
        lines << W.line(tui, *permission_options(tui, theme, perm),
                        (W.span(tui, theme, " or type a reply to reject with a reason", :tx2) if reply_hint))
        tui.paragraph(text: lines, block: tui.block(
          titles: [{ content: W.line(tui, W.span(tui, theme, " ◆ Permission ", :ac, bold: true), W.span(tui, theme, "#{perm.title} ", :tx)) }],
          borders: [:all], border_style: theme.style(:ac), padding: [1, 1, 0, 0]
        ))
      end

      # "› reply to agent…" / the typed text with a cursor, plus a right-hand hint. Two rows.
      def input_row(model, tui, theme, slug, hint:)
        ui = model.ui
        placeholder = model.permission_for(slug) ? "Answer with 1-3, or type to reply…" : "reply to agent…"
        text = if ui.input_focus
                 [W.span(tui, theme, ui.input, :tx), W.span(tui, theme, "▏", :ac)]
               elsif !ui.input.empty?
                 [W.span(tui, theme, ui.input, :tx)]
               else
                 [W.span(tui, theme, placeholder, :tx2)]
               end
        rule = tui.paragraph(text: [W.line(tui, W.span(tui, theme, "─" * 400, :ui))])
        row = tui.layout(direction: :horizontal, constraints: [tui.constraint_fill(1), tui.constraint_length(hint.length + 1)], children: [
          tui.paragraph(text: [W.line(tui, W.span(tui, theme, "› ", :ac), *text)]),
          tui.paragraph(text: [W.line(tui, W.span(tui, theme, hint, :tx2))])
        ])
        tui.layout(direction: :vertical, constraints: [tui.constraint_length(1), tui.constraint_length(1)], children: [rule, row])
      end
    end
  end
end
