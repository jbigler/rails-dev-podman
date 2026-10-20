# frozen_string_literal: true

module Wt
  module Views
    # F3 Chat with one worktree's agent (ui.chat_slug): transcript, permission box
    # and input; ⅔/full add a 46-col context sidebar, ½ a context strip (sidebar on
    # ^b), compact the transcript only (context strip on ^b).
    module Chat
      W = Widgets
      SIDEBAR = 46
      DIFF_LINES = 12

      module_function

      def view(model, tui, theme)
        ui = model.ui
        slug = ui.chat_slug || ui.selected
        return tui.paragraph(text: [W.line(tui, W.span(tui, theme, "No worktree selected.", :tx2))]) unless slug

        wide = %i[twothirds full].include?(ui.tier)
        sidebar = wide ? ui.sidebar : (ui.tier == :half && !ui.sidebar)
        strip = !sidebar && (ui.tier == :half || (ui.tier == :compact && !ui.sidebar))
        main = conversation(model, tui, theme, slug, strip:, width: ui.width - (sidebar ? SIDEBAR + 1 : 0) - 2)
        body = if sidebar
                 tui.layout(direction: :horizontal, constraints: [tui.constraint_fill(1), tui.constraint_length(SIDEBAR)],
                            children: [main, sidebar(model, tui, theme, slug)])
               else main
               end
        tui.layout(direction: :vertical, constraints: [tui.constraint_length(1), tui.constraint_fill(1)],
                   children: [tabs(model, tui, theme, slug), body])
      end

      # "^1 tasks-filtering ◆  ^2 hipaa-logoff ●" … right: the agent and its socket.
      def tabs(model, tui, theme, slug)
        left = model.agents_by_urgency.first(9).each_with_index.flat_map do |s, i|
          cur = s == slug
          [W.span(tui, theme, " ^#{i + 1} #{s} ", cur ? :ac : :tx2, bold: cur), W.glyph(tui, theme, model.agent_state(s)), W.span(tui, theme, " ")]
        end
        name = Session.agent_name(model, slug)
        # Leading gap: the tab strip is clipped at its edge, so it must not run into this label.
        right = "  #{"#{name} · " if name}ACP over .run/#{slug}/acp.sock "
        tui.layout(direction: :horizontal, constraints: [tui.constraint_fill(1), tui.constraint_length(right.length)], children: [
          tui.paragraph(text: [W.line(tui, left)]), tui.paragraph(text: [W.line(tui, W.span(tui, theme, right, :tx2))])
        ])
      end

      def conversation(model, tui, theme, slug, strip:, width:)
        s = model.sessions[slug]
        perm = model.permission_for(slug)
        fixed = 2 + (perm ? 4 : 0) + (strip ? 2 : 0)
        visible = [model.ui.height - 4 - fixed, 1].max
        lines, focus = if s && (!s.transcript.empty? || %i[connected busy ended].include?(s.connection))
                         transcript(model, tui, theme, s, width)
                       else
                         [no_session(model, tui, theme, slug, s), nil]
                       end
        scroll = [lines.size - visible, 0].max
        scroll = focus.clamp(0, scroll) if focus && focus < scroll
        parts = [[tui.constraint_fill(1), tui.paragraph(text: lines, scroll: [scroll, 0])]]
        parts << [tui.constraint_length(2), strip(model, tui, theme, slug)] if strip
        parts << [tui.constraint_length(4), Session.permission_box(model, tui, theme, slug)] if perm
        parts << [tui.constraint_length(2), Session.input_row(model, tui, theme, slug, hint: "⏎ send · ^] back")]
        tui.layout(direction: :vertical, constraints: parts.map(&:first), children: parts.map(&:last))
      end

      def no_session(model, tui, theme, slug, s)
        lines = [W.line(tui, W.span(tui, theme, "No agent session for #{slug}.", :tx, bold: true)), W.line(tui)]
        lines << W.line(tui, W.span(tui, theme, "connecting to .run/#{slug}/acp.sock…", :yel)) if s&.connection == :connecting
        if (st = model.agents[slug])
          lines << W.line(tui, W.span(tui, theme, "status file: ", :tx2), W.glyph(tui, theme, st.state, Session::FILE_STATES.fetch(st.state, st.state.to_s)))
        end
        lines + [W.line(tui),
                 W.line(tui, *W.key_hint(tui, theme, "a", "start a chat"), W.span(tui, theme, "starts agent@#{slug} and connects over ACP", :tx2)),
                 W.line(tui, W.span(tui, theme, "or from a shell: ", :tx2), W.span(tui, theme, "mise run agent:up", :blu))]
      end

      # [lines, index of the selected tool call's line or nil]
      def transcript(model, tui, theme, s, width)
        lines = []
        focus = nil
        if s.started_at.is_a?(Time)
          lines << W.line(tui, W.span(tui, theme, "── session started #{s.started_at.strftime('%H:%M')} · #{s.agent}", :tx2))
          lines << W.line(tui)
        end
        s.transcript.each do |e|
          case e.role
          when :user then lines.concat(wrapped(tui, theme, "› ", :ac, e.text, :tx, width))
          when :agent then lines.concat(markdown(tui, theme, "◇ ", :cyn, e.text, {}, width))
          when :thought then lines.concat(markdown(tui, theme, "∴ ", :tx2, e.text, { fg: :tx2, italic: true }, width))
          when :system then lines.concat(wrapped(tui, theme, "— ", :tx2, e.text, :tx2, width))
          when :tool
            i = s.tool_calls.index { it.id == e.tool_call_id }
            next unless i

            selected = i == model.ui.tool_index
            focus = lines.size if selected
            lines.concat(tool(model, tui, theme, s.tool_calls[i], selected, width))
            next
          end
          lines << W.line(tui)
        end
        case s.connection
        when :busy
          holder = s.error || s.transcript.reverse.find { it.role == :system }&.text
          lines << W.line(tui, W.glyph(tui, theme, :permission, "socket busy — another client holds it"), W.span(tui, theme, holder ? " (#{holder})" : "", :tx2))
        when :ended
          lines << W.line(tui, W.glyph(tui, theme, :offline, "session ended — "), *W.key_hint(tui, theme, "A", "for a new one"))
        end
        [lines, focus]
      end

      # Soft-wrap `text` at `width` with a marker on the first line and an indent after.
      def wrapped(tui, theme, marker, mcolor, text, color, width)
        avail = [width - W.cells(marker), 10].max
        rows = text.to_s.split("\n", -1).flat_map { wrap(it, avail) }
        rows = [""] if rows.empty?
        rows.each_with_index.map do |row, i|
          W.line(tui, W.span(tui, theme, i.zero? ? marker : " " * W.cells(marker), mcolor), W.span(tui, theme, row, color))
        end
      end

      # Agent and thought text is Markdown: rendered rows (Views::Markdown), with the
      # marker on the first row and an indent after.
      def markdown(tui, theme, marker, mcolor, text, base, width)
        indent = W.cells(marker)
        rows = Markdown.rows(text, [width - indent, 10].max, base)
        rows = [[]] if rows.empty?
        rows.each_with_index.map do |row, i|
          W.line(tui, W.span(tui, theme, i.zero? ? marker : " " * indent, mcolor),
                 *row.map { tui.span(content: it.text, style: theme.style(it.style.fetch(:fg, :tx), **it.style.except(:fg))) })
        end
      end

      # Greedy word wrap in display cells; a word wider than a row (a CJK run, a URL)
      # is split at grapheme boundaries.
      def wrap(para, avail)
        rows = []
        row = +""
        para.split.each do |word|
          if !row.empty? && W.cells(row) + 1 + W.cells(word) <= avail
            row << " " << word
            next
          end
          rows << row unless row.empty?
          while W.cells(word) > avail
            # A single grapheme cluster can itself be wider than the row (agent text is
            # untrusted); take it whole rather than loop forever on an empty head.
            piece = W.head(word, avail)
            piece = word.each_grapheme_cluster.first if piece.empty?
            rows << piece
            word = word.delete_prefix(piece)
          end
          row = +word
        end
        rows << row
      end

      def relative(model, slug, path)
        prefix = File.join(model.config.root, slug, "")
        path.to_s.start_with?(prefix) ? path.to_s.delete_prefix(prefix) : path.to_s
      end

      def tool(model, tui, theme, c, selected, width)
        locs = c.locations.map do |l|
          path = relative(model, model.ui.chat_slug || model.ui.selected, l[:path] || l["path"])
          (line = l[:line] || l["line"]) ? "#{path}:#{line}" : path
        end
        what = [c.title, *locs].reject { it.to_s.empty? }.uniq.join("  ")
        out = c.output.to_s.lines.first&.strip
        what += " · #{out}" if out && !out.empty? && c.kind.to_s == "execute"
        hint = selected ? "  o open in nvim · d diff" : ""
        spans = [W.span(tui, theme, "#{Session::STATUS_GLYPHS.fetch(c.status, '?')} ", theme.state_color(c.status)), *Session.kind_spans(tui, theme, c.kind),
                 W.span(tui, theme, W.pad(what, [width - 14 - hint.length - 10, 10].max), :tx),
                 W.span(tui, theme, " #{Session::STATUS_LABELS.fetch(c.status, c.status.to_s)}", theme.state_color(c.status)),
                 W.span(tui, theme, hint, :ac)]
        row = selected ? tui.line(spans:, style: theme.style(:tx, bg: :sel)) : W.line(tui, spans)
        [row, *diff_lines(tui, theme, c.diff, width, all: selected)]
      end

      # +/- lines for an ACP diff ({path:, old_text:, new_text:} or an Array of them):
      # common head/tail trimmed to one context line each side.
      def diff_lines(tui, theme, diff, width, all: false)
        diffs = diff.is_a?(Array) ? diff : [diff].compact
        rows = diffs.flat_map do |d|
          old = (d[:old_text] || d["oldText"]).to_s.split("\n")
          new = (d[:new_text] || d["newText"]).to_s.split("\n")
          head = 0
          head += 1 while head < old.size && head < new.size && old[head] == new[head]
          tail = 0
          tail += 1 while tail < old.size - head && tail < new.size - head && old[-1 - tail] == new[-1 - tail]
          ctx_before = head.positive? ? [[" ", old[head - 1]]] : []
          ctx_after = tail.positive? ? [[" ", old[old.size - tail]]] : []
          hunk = ctx_before + old[head...(old.size - tail)].map { ["-", it] } + new[head...(new.size - tail)].map { ["+", it] } + ctx_after
          hunk.empty? && old.empty? ? [["+", "(empty)"]] : hunk
        end
        rows = rows.first(DIFF_LINES) + [[" ", "… #{rows.size - DIFF_LINES} more lines"]] if !all && rows.size > DIFF_LINES
        rows.map do |sign, text|
          color = { "-" => :red, "+" => :grn }.fetch(sign, :tx2)
          W.line(tui, W.span(tui, theme, "    │ ", :ui), W.span(tui, theme, "#{sign} #{W.truncate(text, [width - 8, 10].max)}", color))
        end
      end

      # --- context -----------------------------------------------------------------

      def pr_spans(model, tui, theme, slug)
        return [W.unknown(tui, theme)] if model.failed?("pr", slug)

        pr = model.prs[slug]
        case pr
        when PrStatus
          state = pr.draft ? "draft" : pr.state.to_s.downcase
          ci = { pass: [:done, "✓"], fail: [:failed, "✗"], pending: [:starting, "◐"] }[pr.ci]
          [W.span(tui, theme, "##{pr.number}", :pur), W.span(tui, theme, " #{state}", :tx2),
           (W.span(tui, theme, " #{ci[1]} #{pr.ci_failed.positive? ? pr.ci_failed : ''}".rstrip, theme.state_color(pr.ci)) if ci)].compact
        when :none then [W.span(tui, theme, "none", :tx2)]
        else [W.span(tui, theme, "…", :tx2)]
        end
      end

      def nvim_lines(model, tui, theme, slug)
        return [W.line(tui, W.unknown(tui, theme), W.span(tui, theme, " nvim unknown", :tx2))] if model.failed?("nvim", slug)

        n = model.nvim[slug]
        port = model.worktree(slug)&.nvim_port
        return [W.line(tui, W.glyph(tui, theme, :stopped, "not running")), W.line(tui, *W.key_hint(tui, theme, "n", "start"))] unless n&.running

        lines = [W.line(tui, W.glyph(tui, theme, :running, "listening#{" · 127.0.0.1:#{port}" if port}")),
                 W.line(tui, W.span(tui, theme, "#{n.ui_count} UI#{'s' unless n.ui_count == 1} attached · #{n.buffers} buffers · #{n.modified} modified", :tx2))]
        lines << W.line(tui, W.span(tui, theme, "buf ", :tx2), W.span(tui, theme, W.truncate_middle("#{File.basename(n.file)}#{":#{n.line}" if n.line}", SIDEBAR - 8), :blu)) if n.file
        lines
      end

      def service_lines(model, tui, theme, slug)
        return [W.line(tui, W.unknown(tui, theme), W.span(tui, theme, " services unknown", :tx2))] if model.failed?("units", slug)

        svcs = model.services[slug] || []
        return [W.line(tui, W.glyph(tui, theme, :stopped, "pod down"))] if svcs.empty?

        svcs.map do |svc|
          W.line(tui, W.span(tui, theme, svc.label.ljust(12), :tx), W.glyph(tui, theme, svc.state, svc.up? && svc.port ? ":#{svc.port}" : svc.state.to_s))
        end
      end

      # Files the agent touched with edit-like tool calls, first-seen order.
      def changes(model, slug)
        s = model.sessions[slug]
        return [] unless s

        s.tool_calls.select { %w[edit delete move].include?(it.kind.to_s) }
         .flat_map { |c| c.locations.map { relative(model, slug, it[:path] || it["path"]) } }.uniq
      end

      def sidebar(model, tui, theme, slug)
        wt = model.worktree(slug)
        head = [W.line(tui, W.span(tui, theme, "HEAD  ", :tx2), W.span(tui, theme, W.truncate_middle(wt&.branch || "(detached)", SIDEBAR - 10), :blu)),
                W.line(tui, W.span(tui, theme, "PR    ", :tx2), *pr_spans(model, tui, theme, slug))]
        nvim = nvim_lines(model, tui, theme, slug)
        svcs = service_lines(model, tui, theme, slug)
        files = changes(model, slug)
        s = model.sessions[slug]
        change_lines = files.map { W.line(tui, W.span(tui, theme, "✎ ", :pur), W.span(tui, theme, W.truncate_middle(it, SIDEBAR - 6), :tx)) }
        change_lines = [W.line(tui, W.span(tui, theme, "no edits yet", :tx2))] if change_lines.empty?
        if s
          change_lines << W.line(tui)
          change_lines << W.line(tui, *Session.title(model, tui, theme, slug).drop(2))
          unless s.plan.empty?
            change_lines << W.line(tui)
            change_lines << W.line(tui, W.span(tui, theme, "plan", :tx, bold: true), W.span(tui, theme, " · #{s.plan_done} of #{s.plan.size}", :tx2))
            change_lines.concat(s.plan.map { Session.plan_entry(tui, theme, it, SIDEBAR - 10) })
          end
        end
        box = ->(title, lines) { W.panel(tui, theme, title:, child: tui.paragraph(text: lines)) }
        tui.layout(direction: :vertical, constraints: [
          tui.constraint_length(head.size + 2), tui.constraint_length(nvim.size + 2), tui.constraint_length(svcs.size + 2), tui.constraint_fill(1)
        ], children: [box.("wt/#{slug}", head), box.("nvim", nvim), box.("Services", svcs), box.("Changes", change_lines)])
      end

      # Two-row summary of the sidebar for narrow tiers.
      def strip(model, tui, theme, slug)
        wt = model.worktree(slug)
        svcs = model.services[slug] || []
        n = model.nvim[slug]
        nvim = if model.failed?("nvim", slug) then W.unknown(tui, theme)
               elsif n&.running then W.glyph(tui, theme, :running, "nvim #{n.ui_count} UI")
               else W.glyph(tui, theme, :stopped, "nvim")
               end
        services = model.failed?("units", slug) ? W.unknown(tui, theme) : W.span(tui, theme, "services #{svcs.count(&:up?)}/#{svcs.size} up", :tx2)
        line1 = W.line(tui, W.span(tui, theme, "HEAD ", :tx2), W.span(tui, theme, W.truncate_middle(wt&.branch || "(detached)", 30), :blu),
                       W.span(tui, theme, " · PR ", :tx2), *pr_spans(model, tui, theme, slug), W.span(tui, theme, " · ", :tx2), nvim,
                       W.span(tui, theme, " · ", :tx2), services, W.span(tui, theme, " · #{changes(model, slug).size} files changed", :tx2))
        line2 = W.line(tui, *W.key_hint(tui, theme, "^b", model.ui.tier == :half ? "sidebar" : "hide context"))
        tui.paragraph(text: [line1, line2], style: theme.style(:tx, bg: :bg2))
      end
    end
  end
end
