# frozen_string_literal: true

module Wt
  module Views
    # Frame shared by every screen: top status bar, screen tabs, the screen body,
    # the key-hint bar, then overlays (help, confirm, prompt, toasts) on top.
    module Root
      W = Widgets
      SCREENS = { worktrees: ["F1", "Worktrees"], agents: ["F2", "Agents"], chat: ["F3", "Chat"] }.freeze

      def self.call(model, tui)
        theme = Theme.for(model.ui.theme, model.ui.accent)
        body = case model.ui.screen
               when :agents then Agents.view(model, tui, theme)
               when :chat then Chat.view(model, tui, theme)
               else Dashboard.view(model, tui, theme)
               end
        screen = tui.layout(direction: :vertical, constraints: [
          tui.constraint_length(1), tui.constraint_length(1), tui.constraint_fill(1), tui.constraint_length(1)
        ], children: [top_bar(model, tui, theme), tab_bar(model, tui, theme), body, hint_bar(model, tui, theme)])
        layers = [tui.block(style: theme.style(:tx, bg: :bg), borders: []), screen, *overlays(model, tui, theme)]
        tui.overlay(layers:)
      end

      def self.top_bar(model, tui, theme)
        wts = model.worktrees
        pods_up = wts.count { |wt| (model.services[wt.slug] || []).any?(&:up?) }
        states = wts.map { model.agent_state(it.slug) }
        needs = states.count(:permission)
        errors = wts.count { |wt| states[wts.index(wt)] == :failed || (model.services[wt.slug] || []).any? { %i[failed exited].include?(it.state) } }
        gh = if model.gh_at then W.span(tui, theme, "gh ✓ #{W.duration(model.now - model.gh_at)} ago  ", :tx2)
             elsif model.failures.keys.any? { it.start_with?("pr:") } then W.span(tui, theme, "gh ?  ", :tx2, dim: true)
             end
        left = [W.span(tui, theme, " wt  ", :ac, bold: true), W.span(tui, theme, model.config.root.sub(Dir.home, "~"), :tx2)]
        right = [
          W.glyph(tui, theme, pods_up.positive? ? :running : :stopped, "pods #{pods_up}/#{wts.size}  "),
          (W.glyph(tui, theme, :permission, "#{needs} needs input  ") if needs.positive?),
          (W.glyph(tui, theme, :failed, "#{errors} error#{'s' unless errors == 1}  ") if errors.positive?),
          gh,
          W.span(tui, theme, model.now.strftime("%H:%M "), :tx)
        ].compact
        split_line(tui, theme, left, right, bg: :bg2)
      end

      def self.tab_bar(model, tui, theme)
        needs = model.agents_by_urgency.count { model.agent_state(it) == :permission }
        tabs = SCREENS.flat_map do |screen, (key, label)|
          active = model.ui.screen == screen
          style = active ? theme.style(:bg, bg: :ac, bold: true) : theme.style(:tx, bg: :bg2)
          spans = [tui.span(content: " #{key} #{label} ", style:)]
          spans << W.span(tui, theme, "◆#{needs} ", :ac) if screen == :agents && needs.positive?
          spans << tui.span(content: "  ")
        end
        ui = model.ui
        right = [W.span(tui, theme, "#{ui.width}×#{ui.height} · #{Tier::LABELS.fetch(ui.tier)} ", :tx2)]
        split_line(tui, theme, [tui.span(content: " "), *tabs], right)
      end

      def self.hint_bar(model, tui, theme)
        hints = Keymap.hints(model.ui.screen)
        quitish = hints.select { %i[toggle_help quit].include?(it.action) }
        left = (hints - quitish).flat_map { W.key_hint(tui, theme, it.key_label, it.label) }
        right = quitish.flat_map { W.key_hint(tui, theme, it.key_label, it.label) }
        split_line(tui, theme, [tui.span(content: " "), *left], right, bg: :bg2)
      end

      # One row with left spans flush left and right spans flush right.
      def self.split_line(tui, theme, left, right, bg: nil)
        rw = right.sum { tui.text_width(it.content) }
        tui.layout(direction: :horizontal, constraints: [tui.constraint_fill(1), tui.constraint_length(rw)], children: [
          tui.paragraph(text: [tui.line(spans: left)], style: theme.style(:tx, bg:)),
          tui.paragraph(text: [tui.line(spans: right)], style: theme.style(:tx, bg:))
        ])
      end

      def self.overlays(model, tui, theme)
        ui = model.ui
        layers = []
        layers << help(model, tui, theme) if ui.help
        layers << confirm(model, tui, theme) if ui.confirm
        layers << prompt(model, tui, theme) if ui.prompt
        layers << toasts(model, tui, theme) unless ui.toasts.empty?
        layers
      end

      # Generated from Keymap::BINDINGS, so it lists exactly what the keys do. Groups
      # are packed into as many columns as the height needs (a group never splits);
      # when that is too wide, the "(screens)" notes go first.
      def self.help(model, tui, theme)
        ui = model.ui
        rows = [ui.height - 4, 1].max
        columns, col_w = help_columns(tui, rows, notes: true)
        columns, col_w = help_columns(tui, rows, notes: false) if columns.size * col_w + 4 > ui.width - 2
        paragraphs = columns.map do |col|
          tui.paragraph(text: col.map { |row| W.line(tui, row.map { |text, fg, bold| W.span(tui, theme, text, fg, bold:) }) },
                        style: theme.style(:tx, bg: :bg))
        end
        body = tui.layout(direction: :horizontal, constraints: columns.map { tui.constraint_length(col_w) }, children: paragraphs)
        width = (columns.size * col_w + 4).clamp(1, [ui.width - 2, 1].max)
        height = (columns.map(&:size).max + 2).clamp(1, [ui.height - 2, 1].max)
        W.centered(tui, width:, height:, child: W.panel(tui, theme, title: "Keys", accent: true, child: body))
      end

      # [[rows of [text, fg, bold]] per column], column width
      def self.help_columns(tui, rows, notes:)
        blocks = Keymap.groups.map do |group, bindings|
          [[[group, :ac, true]],
           *bindings.map do |b|
             where = notes && b.screens != :all ? " (#{b.screens.join(', ')})" : ""
             [["  #{b.key_label.ljust(7)} ", :tx, true], [b.label, :tx, false], [where, :tx2, false]]
           end]
        end
        col_w = blocks.flatten(1).map { |row| tui.text_width(row.sum("") { it[0] }) }.max + 2
        columns = blocks.each_with_object([[]]) do |block, cols|
          cols << [] if !cols.last.empty? && cols.last.size + 1 + block.size > rows
          cols.last.concat(cols.last.empty? ? block : [[], *block])
        end
        [columns, col_w]
      end

      def self.confirm(model, tui, theme)
        c = model.ui.confirm
        body = tui.paragraph(text: [W.line(tui, W.span(tui, theme, c.prompt)), W.line(tui),
                                    W.line(tui, *W.key_hint(tui, theme, "y", "yes"), *W.key_hint(tui, theme, "n", "no"))],
                             wrap: true, style: theme.style(:tx, bg: :bg))
        width = [[c.prompt.length + 6, 60].max, model.ui.width - 4].min.clamp(1, 1000)
        W.centered(tui, width:, height: 6, child: W.panel(tui, theme, title: "Confirm", accent: true, child: body))
      end

      def self.prompt(model, tui, theme)
        p = model.ui.prompt
        body = tui.paragraph(text: [W.line(tui, W.span(tui, theme, "› ", :ac), W.span(tui, theme, p.text), W.span(tui, theme, "▏", :ac))],
                             style: theme.style(:tx, bg: :bg))
        W.centered(tui, width: 60, height: 3, child: W.panel(tui, theme, title: p.label, accent: true, child: body))
      end

      def self.toasts(model, tui, theme)
        toasts = model.ui.toasts
        lines = toasts.map { W.line(tui, W.span(tui, theme, " #{it.level == :error ? '✗' : '·'} #{W.truncate(it.text, 76)} ", it.level == :error ? :red : :tx)) }
        tui.layout(direction: :vertical, flex: :end, constraints: [tui.constraint_length(lines.size + 2), tui.constraint_length(1)], children: [
          tui.layout(direction: :horizontal, flex: :end, constraints: [tui.constraint_length(82)], children: [
            tui.overlay(layers: [tui.clear, tui.paragraph(text: lines, block: tui.block(borders: [:all], border_style: theme.style(:ui)), style: theme.style(:tx, bg: :bg2))])
          ]),
          tui.paragraph(text: "")
        ])
      end
    end
  end
end
