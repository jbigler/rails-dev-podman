# frozen_string_literal: true

module Wt
  module Views
    # F1 Worktrees screen (SPEC "Screens, layout tiers and keys", screens/Main.dc.html).
    #   compact    one pane: the list, or (⏎) branch & stack + pod + agent; Esc back
    #   half       stacked: list, branch & stack, pod, agent
    #   twothirds  list full width; branch & stack beside pod; agent fills the bottom
    #   full       list, branch & stack + pod, service log on the left; 112-col agent column right
    # Views are pure, so the geometry is computed here from ui.width / ui.height and
    # handed to the layout as fixed lengths; rows are padded to exact cell widths so
    # the selection background spans the whole row.
    module Dashboard
      W = Widgets
      AGENT_COLUMN = 112
      GAP = 1           # columns between side-by-side panels
      CHROME_ROWS = 3   # Root's top bar, tab bar and hint bar

      module_function

      def view(model, tui, theme)
        ui = model.ui
        width = ui.width
        height = [ui.height - CHROME_ROWS, 1].max
        case ui.tier
        when :compact then compact(model, tui, theme, width, height)
        when :half then half(model, tui, theme, width, height)
        when :twothirds then twothirds(model, tui, theme, width, height)
        else full(model, tui, theme, width, height)
        end
      end

      def compact(model, tui, theme, width, height)
        slug = model.selected_worktree&.slug
        return List.panel(model, tui, theme, width, rows: height - List::CHROME) unless model.ui.detail && slug

        stack = Branch.panel(model, tui, theme, slug, width)
        pod = Pod.panel(model, tui, theme, slug, width)
        agent_h = height - stack.last - pod.last
        vertical(tui, [[stack.first, stack.last], [pod.first, pod.last], [agent(model, tui, theme, slug, agent_h), nil]])
      end

      def half(model, tui, theme, width, height)
        slug = model.selected_worktree&.slug
        list_h = List.height(model, height / 3)
        list = List.panel(model, tui, theme, width, rows: list_h - List::CHROME)
        return vertical(tui, [[list, list_h], [tui.paragraph(text: ""), nil]]) unless slug

        stack = Branch.panel(model, tui, theme, slug, width)
        pod = Pod.panel(model, tui, theme, slug, width)
        agent_h = height - list_h - stack.last - pod.last
        vertical(tui, [[list, list_h], [stack.first, stack.last], [pod.first, pod.last], [agent(model, tui, theme, slug, agent_h), nil]])
      end

      def twothirds(model, tui, theme, width, height)
        slug = model.selected_worktree&.slug
        list_h = List.height(model, height / 3)
        list = List.panel(model, tui, theme, width, rows: list_h - List::CHROME)
        return vertical(tui, [[list, list_h], [tui.paragraph(text: ""), nil]]) unless slug

        middle, middle_h = side_by_side(model, tui, theme, slug, width)
        agent_h = height - list_h - middle_h
        vertical(tui, [[list, list_h], [middle, middle_h], [agent(model, tui, theme, slug, agent_h), nil]])
      end

      def full(model, tui, theme, width, height)
        slug = model.selected_worktree&.slug
        left_w = width - AGENT_COLUMN - GAP
        list_h = List.height(model, height / 3)
        list = List.panel(model, tui, theme, left_w, rows: list_h - List::CHROME)
        left = if slug
                 middle, middle_h = side_by_side(model, tui, theme, slug, left_w)
                 logs_h = height - list_h - middle_h
                 vertical(tui, [[list, list_h], [middle, middle_h], [Logs.panel(model, tui, theme, slug, left_w, logs_h), nil]])
               else
                 vertical(tui, [[list, list_h], [tui.paragraph(text: ""), nil]])
               end
        right = slug ? agent(model, tui, theme, slug, height) : tui.paragraph(text: "")
        beside(tui, left, left_w, right, AGENT_COLUMN)
      end

      # Branch & stack beside the pod panel, both as tall as the taller one.
      def side_by_side(model, tui, theme, slug, width)
        left_w = (width - GAP) / 2
        right_w = width - GAP - left_w
        stack = Branch.panel(model, tui, theme, slug, left_w)
        pod = Pod.panel(model, tui, theme, slug, right_w)
        [beside(tui, stack.first, left_w, pod.first, right_w), [stack.last, pod.last].max]
      end

      # Two widgets side by side with a GAP-column blank between them.
      def beside(tui, left, left_w, right, right_w)
        tui.layout(direction: :horizontal,
                   constraints: [tui.constraint_length(left_w), tui.constraint_length(GAP), tui.constraint_length(right_w)],
                   children: [left, tui.paragraph(text: ""), right])
      end

      # The agent panel: Views::Session content inside an accent border.
      def agent(model, tui, theme, slug, height)
        rows = [height - 2 - 8, 3].max
        W.panel(tui, theme, title: Session.title(model, tui, theme, slug), accent: true,
                            child: Session.panel(model, tui, theme, slug, rows:))
      end

      # parts: [[widget, rows or nil (fill)]]
      def vertical(tui, parts)
        tui.layout(direction: :vertical,
                   constraints: parts.map { |_, h| h ? tui.constraint_length(h) : tui.constraint_fill(1) },
                   children: parts.map(&:first))
      end

      # ── row building ────────────────────────────────────────────────────────

      # Inner width of a Widgets.panel `width` cells wide (borders + 1-col padding each side).
      def inner(width) = [width - 4, 0].max

      # spans cut to exactly `width` cells (last kept span ellipsised), padded with
      # spaces; every span gets background `bg` when given.
      def fit(tui, theme, spans, width, bg: nil)
        out = []
        left = width
        spans.compact.each do |sp|
          break if left <= 0

          text = sp.content.to_s
          w = tui.text_width(text)
          if w > left
            text = W.truncate(text, left)
            w = tui.text_width(text)
          end
          out << on_bg(sp, theme, bg, text)
          left -= w
        end
        out << tui.span(content: " " * left, style: theme.style(:tx, bg:)) if left.positive?
        out
      end

      def on_bg(span, theme, bg, text = span.content)
        return span.with(content: text) unless bg

        style = span.style || RatatuiRuby::Style::Style.default
        span.with(content: text, style: style.with(bg: theme[bg]))
      end

      # One line of fixed-width cells separated by one space. cells: [[spans, width]]
      def cells(tui, theme, cells, bg: nil)
        spans = cells.each_with_index.flat_map do |(content, w), i|
          sep = i.zero? ? [] : [tui.span(content: " ", style: theme.style(:tx, bg:))]
          sep + fit(tui, theme, Array(content), w, bg:)
        end
        tui.line(spans:)
      end

      # Left spans flush left, right spans flush right, in exactly `width` cells.
      def spread(tui, theme, left, right, width, bg: nil)
        rw = right.compact.sum { tui.text_width(it.content) }
        return tui.line(spans: fit(tui, theme, left, width, bg:)) if rw >= width

        tui.line(spans: fit(tui, theme, left, width - rw, bg:) + right.compact.map { on_bg(it, theme, bg) })
      end

      # A key chip with a custom chip colour (Widgets.key_hint always uses tx2).
      def chip(tui, theme, key, label, bg: :tx2)
        [tui.span(content: " #{key} ", style: theme.style(:bg, bg:, bold: true)), W.span(tui, theme, " #{label}  ", :tx)]
      end

      def rule(tui, theme, width) = W.line(tui, W.span(tui, theme, "┄" * width, :ui))
    end
  end
end

require_relative "dashboard/list"
require_relative "dashboard/branch"
require_relative "dashboard/pod"
require_relative "dashboard/logs"
