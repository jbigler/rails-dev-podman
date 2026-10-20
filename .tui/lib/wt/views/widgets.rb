# frozen_string_literal: true

module Wt
  module Views
    # Small building blocks shared by every screen. All take the Theme explicitly;
    # nothing here reads global state.
    module Widgets
      module_function

      # A bordered panel with a title on the top border ("Worktrees 6 · 4 agents").
      # title: String or [Span]; children: one widget drawn inside.
      def panel(tui, theme, title:, child:, accent: false)
        title_spans = title.is_a?(Array) ? title : [tui.span(content: title, style: theme.style(accent ? :ac : :tx, bold: true))]
        tui.block(
          titles: [{ content: tui.line(spans: [tui.span(content: " "), *title_spans, tui.span(content: " ")]) }],
          borders: [:all],
          border_style: theme.style(accent ? :ac : :ui),
          padding: [1, 1, 0, 0],
          children: [child]
        )
      end

      # [Span] for a key chip followed by its label: "▐s▌ pod up/down".
      def key_hint(tui, theme, key, label)
        [tui.span(content: " #{key} ", style: theme.style(:bg, bg: :tx2, bold: true)),
         tui.span(content: " #{label}  ", style: theme.style(:tx))]
      end

      # The glyph for a state, coloured by role. States are never told apart by colour alone.
      def glyph(tui, theme, state, text = nil)
        g = Theme::GLYPHS.fetch(state, "?")
        tui.span(content: text ? "#{g} #{text}" : g, style: theme.style(theme.state_color(state)))
      end

      # The dimmed `?` a cell shows when its source failed or timed out.
      def unknown(tui, theme) = tui.span(content: "?", style: theme.style(:tx2, dim: true))

      def span(tui, theme, text, fg = :tx, **) = tui.span(content: text.to_s, style: theme.style(fg, **))
      def line(tui, *spans) = tui.line(spans: spans.flatten.compact)
      def text(tui, lines) = tui.paragraph(text: lines)

      # Display width in cells (box glyphs and CJK count correctly).
      def width(_tui, str) = cells(str)
      def cells(str) = RatatuiRuby::Text.width(str.to_s)

      # Truncate to `max` cells with a trailing ellipsis.
      def truncate(str, max)
        str = str.to_s
        return str if cells(str) <= max
        return head(str, max) if max < 2

        "#{head(str, max - 1)}…"
      end

      # Middle-truncate ("intake/…/questionnaire-model") so both ends of a branch stay readable.
      def truncate_middle(str, max)
        str = str.to_s
        return str if cells(str) <= max
        return truncate(str, max) if max < 5

        keep = max - 1
        "#{head(str, keep / 2)}…#{tail(str, keep - keep / 2)}"
      end

      def pad(str, width)
        s = truncate(str, width)
        s + (" " * [width - cells(s), 0].max)
      end

      # The longest prefix / suffix of `str` at most `max` cells wide.
      def head(str, max) = within(str.each_grapheme_cluster, max).join
      def tail(str, max) = within(str.each_grapheme_cluster.reverse_each, max).reverse.join

      def within(graphemes, max)
        used = 0
        graphemes.take_while { (used += cells(it)) <= max }
      end

      # "1h40m", "8s", "3d"
      def duration(seconds)
        return "—" unless seconds

        s = seconds.to_i
        if s < 60 then "#{s}s"
        elsif s < 3600 then "#{s / 60}m"
        elsif s < 86_400 then "#{s / 3600}h#{(s % 3600) / 60}m"
        else "#{s / 86_400}d"
        end
      end

      # Fixed-size popup centred over the screen: [layers] for tui.overlay.
      def centered(tui, width:, height:, child:)
        tui.layout(direction: :vertical, flex: :center, constraints: [tui.constraint_length(height)], children: [
          tui.layout(direction: :horizontal, flex: :center, constraints: [tui.constraint_length(width)], children: [
            tui.overlay(layers: [tui.clear, child])
          ])
        ])
      end
    end
  end
end
