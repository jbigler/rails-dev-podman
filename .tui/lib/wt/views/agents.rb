# frozen_string_literal: true

module Wt
  module Views
    # F2 Agents: every worktree's agent in urgency order, as cards (max two rows,
    # the rest one line each) or a list (`v`), plus Needs attention and a feed of
    # session updates across worktrees.
    module Agents
      W = Widgets
      COLUMNS = { half: 3, twothirds: 4, full: 6 }.freeze
      CARD_ROWS = 2
      CARD_HEIGHT = 12
      LABELS = { permission: "PERMISSION", failed: "FAILED", running: "RUNNING", done: "DONE", offline: "OFFLINE" }.freeze
      WORDS = { permission: "permission", failed: "failed", running: "running", done: "done", offline: "offline" }.freeze

      module_function

      def view(model, tui, theme)
        slugs = model.agents_by_urgency
        ui = model.ui
        cards = ui.agents_view == :cards && ui.tier != :compact && !slugs.empty?
        top_content, top_height = cards ? cards_area(model, tui, theme, slugs) : list_area(model, tui, theme, slugs)
        top = W.panel(tui, theme, title: title(model, tui, theme, slugs), child: top_content)
        top_height = [top_height + 2, ui.height - 12].min.clamp(5, 1000)
        attention = attention_panel(model, tui, theme, slugs)
        bottom = if %i[twothirds full].include?(ui.tier)
                   tui.layout(direction: :horizontal, constraints: [tui.constraint_percentage(36), tui.constraint_fill(1)],
                              children: [attention, updates_panel(model, tui, theme)])
                 else attention
                 end
        tui.layout(direction: :vertical, constraints: [tui.constraint_length(top_height), tui.constraint_fill(1)], children: [top, bottom])
      end

      # "Agents 10 · 2 need input · 1 failed · 4 running · 3 done": always every agent.
      def title(model, tui, theme, slugs)
        counts = slugs.map { model.agent_state(it) }.tally
        parts = [[:permission, "need input", :ac], [:failed, "failed", :red], [:running, "running", :tx2], [:done, "done", :tx2], [:offline, "offline", :tx2]]
        [W.span(tui, theme, "Agents", :tx, bold: true), W.span(tui, theme, " #{slugs.size}", :tx2),
         *parts.filter_map { |st, word, c| counts[st] && W.span(tui, theme, " · #{counts[st]} #{word}", c) }]
      end

      def key_label(i) = i < 9 ? "^#{i + 1}" : ""

      def age(model, slug)
        s = model.sessions[slug]
        t = s&.started_at || model.agents[slug]&.updated_at
        t.is_a?(Time) ? W.duration(model.now - t) : ""
      end

      def branch(model, slug) = model.worktree(slug)&.branch || model.git[slug]&.branch || "(detached)"

      def nvim_spans(model, tui, theme, slug)
        return [W.unknown(tui, theme)] if model.failed?("nvim", slug)

        n = model.nvim[slug]
        return [W.glyph(tui, theme, :stopped, "stopped")] unless n&.running

        [W.glyph(tui, theme, :running, "#{n.ui_count} UI#{'s' unless n.ui_count == 1}")]
      end

      # The one line about what the agent is doing / waiting for.
      def last_spans(model, tui, theme, slug, width)
        if (perm = model.permission_for(slug))
          return [W.glyph(tui, theme, :permission, W.truncate(perm.title, width - 9)), W.span(tui, theme, "  1-3", :ac, bold: true)]
        end

        s = Session.live(model, slug)
        if s && (c = s.tool_calls.last)
          glyph = Theme::KIND_GLYPHS.fetch(c.kind.to_s, "·")
          return [W.span(tui, theme, "#{Session::STATUS_GLYPHS.fetch(c.status, '?')} ", theme.state_color(c.status)),
                  W.span(tui, theme, "#{glyph} ", theme.kind_color(c.kind.to_s)),
                  W.span(tui, theme, W.truncate("#{c.kind} #{c.title}", width - 4), :tx)]
        end
        return [W.span(tui, theme, W.truncate(s.error, width), :red)] if s&.error

        text = model.agents[slug]&.last || s&.stop_reason&.to_s || ""
        [W.span(tui, theme, W.truncate(text, width), :tx2)]
      end

      def plan_spans(model, tui, theme, slug, cells: 8)
        pp = Session.plan_progress(model, slug)
        return [W.span(tui, theme, "—", :tx2)] unless pp

        [W.span(tui, theme, Session.bar(*pp, cells), :ac), W.span(tui, theme, " #{pp[0]}/#{pp[1]}", :tx2)]
      end

      # --- cards ---------------------------------------------------------------

      def cards_area(model, tui, theme, slugs)
        cols = COLUMNS.fetch(model.ui.tier)
        shown = slugs.first(cols * CARD_ROWS)
        rest = slugs.drop(shown.size)
        rows = shown.each_slice(cols).map do |row|
          cells = row.map { card(model, tui, theme, it, slugs.index(it)) }
          cells << tui.paragraph(text: "") while cells.size < cols
          tui.layout(direction: :horizontal, constraints: Array.new(cols) { tui.constraint_fill(1) }, children: cells)
        end
        parts = rows.map { [tui.constraint_length(CARD_HEIGHT), it] }
        unless rest.empty?
          more = W.line(tui, W.span(tui, theme, "+#{rest.size} more · ↓ to scroll · ", :tx2), *W.key_hint(tui, theme, "v", "list view"))
          lines = [more, *rest.map { row_line(model, tui, theme, it, slugs.index(it)) }]
          parts << [tui.constraint_length(lines.size), tui.paragraph(text: lines)]
        end
        height = rows.size * CARD_HEIGHT + (rest.empty? ? 0 : rest.size + 1)
        [tui.layout(direction: :vertical, constraints: parts.map(&:first), children: parts.map(&:last)), height]
      end

      def card(model, tui, theme, slug, i)
        state = model.agent_state(slug)
        width = [(model.ui.width - 4) / COLUMNS.fetch(model.ui.tier) - 4, 10].max
        s = model.sessions[slug]
        agent = Session.agent_name(model, slug).to_s
        badge = " #{Theme::GLYPHS.fetch(state)} #{LABELS.fetch(state)} "
        since = "  #{age(model, slug)}"
        lines = [
          W.line(tui, tui.span(content: badge, style: theme.style(:bg, bg: theme.state_color(state), bold: true)),
                 W.span(tui, theme, since.ljust([width - badge.length - agent.length, since.length].max), :tx2),
                 W.span(tui, theme, agent, :tx2)),
          W.line(tui, W.span(tui, theme, "HEAD  ", :tx2), W.span(tui, theme, W.truncate_middle(branch(model, slug), width - 6), :blu)),
          W.line(tui, W.span(tui, theme, "nvim  ", :tx2), *nvim_spans(model, tui, theme, slug)),
          W.line(tui),
          W.line(tui, W.span(tui, theme, "plan  ", :tx2), *plan_spans(model, tui, theme, slug))
        ]
        plan = s&.plan || []
        cur = plan.index { it.status != :completed } || plan.size
        window = plan[[cur - 1, 0].max, 3] || []
        lines.concat(window.map { Session.plan_entry(tui, theme, it, width - 4) })
        lines << W.line(tui) while lines.size < 8
        lines << W.line(tui, W.span(tui, theme, "─" * width, :ui))
        lines << W.line(tui, *last_spans(model, tui, theme, slug, width))
        selected = i == model.ui.agents_index
        accent = selected || state == :permission
        color = state == :failed ? :red : (accent ? :ac : :ui)
        tui.paragraph(text: lines, block: tui.block(
          titles: [{ content: W.line(tui, W.span(tui, theme, " #{key_label(i)} ", :tx2), W.span(tui, theme, "#{slug} ", color == :ui ? :tx : color, bold: true)) }],
          borders: [:all], border_style: theme.style(color, bold: selected), padding: [1, 1, 0, 0]
        ))
      end

      # --- list ------------------------------------------------------------------

      def list_area(model, tui, theme, slugs)
        return [tui.paragraph(text: [W.line(tui, W.span(tui, theme, "No agents. a on a worktree starts one (mise run agent:up).", :tx2))]), 1] if slugs.empty?

        header = W.line(tui, W.span(tui, theme, header_text(model), :tx2))
        lines = [header, *slugs.each_with_index.map { |slug, i| row_line(model, tui, theme, slug, i) }]
        footer = model.ui.tier == :compact ? nil : W.line(tui, W.span(tui, theme, "", :tx2), *W.key_hint(tui, theme, "v", "cards"))
        lines << footer if footer
        [tui.paragraph(text: lines), lines.size]
      end

      def wide?(model) = model.ui.width >= 120

      def header_text(model)
        cols = ["  KEY ", "STATE        ", "WORKTREE            "]
        cols += ["AGENT     ", "HEAD                          ", "PLAN           ", "NVIM       ", "SESSION "] if wide?(model)
        "#{cols.join}NOW / LAST"
      end

      # KEY STATE WORKTREE [AGENT HEAD PLAN NVIM SESSION] NOW/LAST
      def row_line(model, tui, theme, slug, i)
        state = model.agent_state(slug)
        selected = i == model.ui.agents_index
        spans = [W.span(tui, theme, selected ? "▌ " : "  ", :ac), W.span(tui, theme, key_label(i).ljust(4), :tx2),
                 W.glyph(tui, theme, state, WORDS.fetch(state).ljust(11)), W.span(tui, theme, " "),
                 W.span(tui, theme, W.pad(slug, 19) + " ", :tx)]
        if wide?(model)
          plan = plan_spans(model, tui, theme, slug, cells: 8)
          plan_w = plan.sum { it.content.length }
          spans += [W.span(tui, theme, W.pad(Session.agent_name(model, slug), 9) + " ", :tx2),
                    W.span(tui, theme, W.pad(W.truncate_middle(branch(model, slug), 29), 29) + " ", :blu),
                    *plan, W.span(tui, theme, " " * [15 - plan_w, 1].max),
                    *nvim_spans(model, tui, theme, slug).map { tui.span(content: W.pad(it.content, 10) + " ", style: it.style) },
                    W.span(tui, theme, W.pad(age(model, slug), 7) + " ", :tx2)]
        end
        spans += last_spans(model, tui, theme, slug, 60)
        selected ? tui.line(spans:, style: theme.style(:tx, bg: :sel)) : W.line(tui, spans)
      end

      # --- needs attention / updates ----------------------------------------------

      def attention_panel(model, tui, theme, slugs)
        items = slugs.each_with_index.select { |slug, _| %i[permission failed].include?(model.agent_state(slug)) }
        lines = items.flat_map do |slug, i|
          state = model.agent_state(slug)
          head = W.line(tui, W.glyph(tui, theme, state), W.span(tui, theme, " #{key_label(i)} #{slug}", state == :failed ? :red : :ac, bold: true),
                        W.span(tui, theme, " #{Session.agent_name(model, slug)} · #{age(model, slug)}", :tx2))
          body = if (perm = model.permission_for(slug))
                   call = model.sessions[slug].tool_calls.find { it.id == perm.tool_call_id }
                   [W.line(tui, W.span(tui, theme, call ? "#{Theme::KIND_GLYPHS.fetch(call.kind.to_s, '·')} #{call.title}" : perm.title, :blu)),
                    W.line(tui, *Session.permission_options(tui, theme, perm), *W.key_hint(tui, theme, "⏎", "chat"))]
                 else
                   err = model.sessions[slug]&.error || model.sessions[slug]&.tool_calls&.last&.title || model.agents[slug]&.last || "failed"
                   [W.line(tui, W.span(tui, theme, W.truncate(err, 200), :tx)), W.line(tui, *W.key_hint(tui, theme, "⏎", "chat"))]
                 end
          [head, *body, W.line(tui)]
        end
        lines = [W.line(tui, W.span(tui, theme, "nothing needs you", :tx2))] if lines.empty?
        W.panel(tui, theme, title: [W.span(tui, theme, "Needs attention", :ac, bold: true), W.span(tui, theme, " #{items.size}", :tx2)],
                            accent: !items.empty?, child: tui.paragraph(text: lines))
      end

      def updates_panel(model, tui, theme)
        calls = model.sessions.flat_map { |slug, s| s.tool_calls.map { [slug, it] } }
                     .select { |_, c| c.at.is_a?(Time) }.sort_by { |_, c| -c.at.to_f }.first(model.ui.height)
        lines = calls.map do |slug, c|
          W.line(tui, W.span(tui, theme, c.at.strftime("%H:%M:%S  "), :tx2), W.span(tui, theme, W.pad(slug, 18) + " ", :blu),
                 *Session.kind_spans(tui, theme, c.kind), W.span(tui, theme, W.pad([c.title, Session.location(c)].compact.uniq.join("  "), 70) + " ", :tx),
                 Session.status_span(tui, theme, c.status))
        end
        lines = [W.line(tui, W.span(tui, theme, "no session updates yet", :tx2))] if lines.empty?
        W.panel(tui, theme, title: [W.span(tui, theme, "Session updates", :tx, bold: true), W.span(tui, theme, " all worktrees · follow ●", :tx2)],
                            child: tui.paragraph(text: lines))
      end
    end
  end
end
