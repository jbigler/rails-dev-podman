# frozen_string_literal: true

module Wt
  module Views
    module Dashboard
      # Full tier only: the tail of the followed service log (`ui.log_service`) under the list.
      module Logs
        W = Widgets
        D = Dashboard

        module_function

        def panel(model, tui, theme, slug, width, height)
          w = D.inner(width)
          rows = [height - 2, 0].max
          stream = model.log_stream
          lines = if stream&.slug != slug || stream.svc != model.ui.log_service
                    [W.line(tui, *W.key_hint(tui, theme, "L", "to follow #{model.ui.log_service} logs"))]
                  elsif model.log_lines.empty?
                    [W.line(tui, W.span(tui, theme, "no #{model.ui.log_service} output yet", :tx2)), W.line(tui),
                     W.line(tui, *W.key_hint(tui, theme, "L", "follow logs"))]
                  else
                    model.log_lines.last(rows).map { W.line(tui, W.span(tui, theme, W.truncate(it, w), color(it))) }
                  end
          W.panel(tui, theme, title: title(model, tui, theme, slug), child: tui.paragraph(text: lines))
        end

        # "Logs rails · postgres · redis · rustfs · playwright", the followed one in accent.
        def title(model, tui, theme, slug)
          current = model.ui.log_service
          names = List.service_list(model, slug).flat_map do |svc|
            [W.span(tui, theme, " · ", :tx2), W.span(tui, theme, svc.label, svc.name == current ? :ac : :tx2)]
          end
          [W.span(tui, theme, "Logs", :tx, bold: true), W.span(tui, theme, " "), *names.drop(1)]
        end

        def color(line)
          case line
          when /error|exception|fatal|refused/i then :red
          when /\A\s*↳/ then :yel
          when /\ACompleted [23]\d\d/, /ready/i then :grn
          when /\A(Started|\s)/ then :tx2
          else :tx
          end
        end
      end
    end
  end
end
