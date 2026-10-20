# frozen_string_literal: true

module Wt
  module Views
    # Agent replies are Markdown (Claude writes GitHub-flavoured). This renders the
    # subset that shows up in practice into rows that fit a width: headings,
    # paragraphs (soft line breaks joined, as CommonMark does), bullet / numbered /
    # task lists, fenced code (kept verbatim: spaces intact, long lines broken, not
    # reflowed), block quotes, rules, pipe tables (aligned columns, cells wrapped
    # when the table is too wide) and inline code, bold, italic, strikethrough and
    # links. Anything else shows as its text. An unterminated fence — a reply still
    # streaming in — runs to the end.
    #
    # Pure: text in, rows of Seg out. A Seg's style is a Hash of Theme#style keywords
    # plus :fg (a palette role), so Chat turns it into spans and tests need no terminal.
    module Markdown
      Seg = Data.define(:text, :style)

      FENCE = /\A\s{0,3}(`{3,}|~{3,})/
      HEADING = /\A\s{0,3}(\#{1,6})\s+(.*?)(?:\s+#+)?\s*\z/
      HR = /\A\s{0,3}([-*_])(?:\s*\1){2,}\s*\z/
      QUOTE = /\A\s{0,3}>\s?(.*)\z/
      ITEM = /\A(\s*)([-*+]|\d{1,9}[.)])\s+(.*)\z/
      TABLE_SEP = /\A\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*\z/
      INLINE = /
        (?<tick>`+)(?<code>.+?)\k<tick>
        | \*\*(?<bold>.+?)\*\*
        | __(?<bold2>.+?)__
        | ~~(?<strike>.+?)~~
        | \*(?!\s)(?<em>.+?)(?<!\s)\*
        | (?<![[:alnum:]])_(?!\s)(?<em2>.+?)(?<!\s)_(?![[:alnum:]])
        | \[(?<label>[^\]]+)\]\((?<url>[^)\s]+)\)
      /x
      ESCAPE = /\\([!-\/:-@\[-`{-~])/
      SEP = " │ "

      module_function

      # text → [[Seg]], each row at most `width` cells. base: style of plain text.
      def rows(text, width, base = {})
        width = [width, 4].max
        blocks(text.to_s.gsub("\t", "    ").split("\n")).each_with_object([]) do |block, out|
          out << [] unless out.empty?
          out.concat(render(block, width, base))
        end
      end

      # The first line of a reply as plain text, for one-line previews: block markers
      # (#, -, 1., >, fences) and inline markup dropped.
      def preview(text)
        line = text.to_s.lines.map(&:strip).find { !it.empty? && !it.match?(FENCE) && !it.match?(HR) }.to_s
        inline(line.sub(/\A(?:\#{1,6}|[-*+]|\d{1,9}[.)]|>)\s+/, ""), {}).sum("", &:text).squeeze(" ").strip
      end

      # --- blocks -----------------------------------------------------------

      def blocks(lines)
        out = []
        i = 0
        while i < lines.size
          line = lines[i]
          if line.strip.empty?
            i += 1
          elsif (m = FENCE.match(line))
            close = /\A\s*#{Regexp.escape(m[1][0])}{#{m[1].size},}\s*\z/
            body = []
            i += 1
            (body << lines[i]; i += 1) while i < lines.size && !lines[i].match?(close)
            i += 1
            out << [:code, body]
          elsif (m = HEADING.match(line))
            out << [:heading, m[1].size, m[2]]
            i += 1
          elsif line.match?(HR)
            out << [:hr]
            i += 1
          elsif table_start?(lines, i)
            rows = [line]
            aligns = alignments(lines[i + 1])
            i += 2
            (rows << lines[i]; i += 1) while i < lines.size && lines[i].include?("|") && !lines[i].strip.empty?
            out << [:table, aligns, rows.map { cells(it) }]
          elsif QUOTE.match?(line)
            body = []
            (body << QUOTE.match(lines[i])[1]; i += 1) while i < lines.size && QUOTE.match?(lines[i])
            out << [:quote, body]
          elsif ITEM.match?(line)
            items, i = list(lines, i)
            out << [:list, items]
          else
            text = [line.strip]
            i += 1
            (text << lines[i].strip; i += 1) while i < lines.size && !lines[i].strip.empty? && !starts_block?(lines, i)
            out << [:paragraph, text.join(" ")]
          end
        end
        out
      end

      def starts_block?(lines, i)
        l = lines[i]
        [FENCE, HEADING, HR, QUOTE, ITEM].any? { l.match?(it) } || table_start?(lines, i)
      end

      def table_start?(lines, i)
        lines[i].include?("|") && lines[i + 1].to_s.include?("-") && lines[i + 1].to_s.match?(TABLE_SEP)
      end

      # Items as [level, marker, text]. A non-item line continues the item above
      # (lazy continuation); a blank line ends the list unless an indented line or
      # another item follows.
      def list(lines, i)
        items = []
        while i < lines.size
          line = lines[i]
          if (m = ITEM.match(line))
            items << [m[1].size / 2, m[2], m[3].strip]
          elsif line.strip.empty?
            nxt = lines[i + 1].to_s
            break unless ITEM.match?(nxt) || (nxt.start_with?("  ") && !nxt.strip.empty?)
          elsif line.start_with?(" ") || !starts_block?(lines, i)
            items.last[2] = "#{items.last[2]} #{line.strip}"
          else
            break
          end
          i += 1
        end
        [items, i]
      end

      # "| a | `x|y` | b |" → ["a", "`x|y`", "b"]: pipes inside code spans and \| stay.
      def cells(line)
        s = line.strip.delete_prefix("|")
        s = s.delete_suffix("|") unless s.end_with?("\\|")
        out = [+""]
        tick = false
        s.each_char.with_index do |c, k|
          if c == "`" then tick = !tick
          elsif c == "|" && !tick && s[k - 1] != "\\"
            out << +""
            next
          end
          out.last << c
        end
        out.map { it.strip.gsub("\\|", "|") }
      end

      def alignments(sep)
        cells(sep).map do |c|
          if c.start_with?(":") && c.end_with?(":") then :center
          elsif c.end_with?(":") then :right
          else :left
          end
        end
      end

      # --- rendering --------------------------------------------------------

      def render(block, width, base)
        case block[0]
        when :paragraph then wrap(inline(block[1], base), width)
        when :heading
          style = base.merge(bold: true, fg: block[1] <= 2 ? :ac : base.fetch(:fg, :tx))
          wrap(inline(block[2], style), width)
        when :hr then [[Seg.new("─" * width, { fg: :ui })]]
        when :code then code(block[1], width, base)
        when :quote
          rows(block[1].join("\n"), width - 2, base.merge(fg: :tx2, italic: true)).map { [Seg.new("│ ", { fg: :ui }), *it] }
        when :list then list_rows(block[1], width, base)
        when :table then table(block[1], block[2], width, base)
        end
      end

      def code(body, width, base)
        lines = body.flat_map { |l| l.empty? ? [""] : chop(l, width) }
        lines = [""] if lines.empty?
        w = [lines.map { Widgets.cells(it) }.max, width].min
        style = { fg: base.fetch(:fg, :tx), bg: :bg2 }
        lines.map { [Seg.new(it + " " * [w - Widgets.cells(it), 0].max, style)] }
      end

      def list_rows(items, width, base)
        items.flat_map do |level, marker, text|
          bullet = marker.match?(/\d/) ? "#{marker} " : (level.even? ? "• " : "◦ ")
          if (m = text.match(/\A\[([ xX])\]\s+(.*)\z/))
            bullet = m[1] == " " ? "☐ " : "☑ "
            text = m[2]
          end
          lead = "  " * [level, 4].min
          hang = Widgets.cells(lead + bullet)
          wrap(inline(text, base), [width - hang, 4].max).each_with_index.map do |row, k|
            [Seg.new(k.zero? ? lead + bullet : " " * hang, { fg: :tx2 }), *row]
          end
        end
      end

      # Columns sized to their content; when the table is wider than `width` the
      # widest columns give way first and their cells wrap.
      def table(aligns, rows, width, base)
        n = rows.map(&:size).max
        rows = rows.map { |r| r + [""] * (n - r.size) }
        segs = rows.each_with_index.map { |r, k| r.map { inline(it, k.zero? ? base.merge(bold: true) : base) } }
        widths = (0...n).map { |c| segs.map { |r| r[c].sum { Widgets.cells(it.text) } }.max.then { [it, 1].max } }
        room = width - (n - 1) * SEP.size
        # Too narrow for columns at all: one wrapped line per row instead.
        return segs.flat_map { |r| wrap(r.each_with_index.flat_map { |c, k| k.zero? ? c : [Seg.new(SEP, { fg: :ui }), *c] }, width) } if room < n

        widths[widths.index(widths.max)] -= 1 while widths.sum > room
        rule = [Seg.new(widths.map { "─" * it }.join("─┼─"), { fg: :ui })]
        body = segs.flat_map { |r| table_row(r, widths, aligns) }
        header_rows = table_row(segs.first, widths, aligns).size
        [*body.first(header_rows), rule, *body.drop(header_rows)]
      end

      def table_row(row, widths, aligns)
        wrapped = row.each_with_index.map { |cell, c| wrap(cell, widths[c]) }
        height = wrapped.map(&:size).max
        (0...height).map do |h|
          wrapped.each_with_index.flat_map do |lines, c|
            line = lines[h] || []
            pad = widths[c] - line.sum { Widgets.cells(it.text) }
            left = case aligns[c]
                   when :right then pad
                   when :center then pad / 2
                   else 0
                   end
            cell = [Seg.new(" " * left, {}), *line, Seg.new(" " * (pad - left), {})]
            c.zero? ? cell : [Seg.new(SEP, { fg: :ui }), *cell]
          end
        end
      end

      # --- inline -----------------------------------------------------------

      def inline(text, style)
        out = []
        pos = 0
        text.to_enum(:scan, INLINE).each do
          m = Regexp.last_match
          out << Seg.new(unescape(text[pos...m.begin(0)]), style) if m.begin(0) > pos
          pos = m.end(0)
          if m[:code] then out << Seg.new(m[:code].strip, style.merge(fg: :cyn))
          elsif (t = m[:bold] || m[:bold2]) then out.concat(inline(t, style.merge(bold: true)))
          elsif m[:strike] then out.concat(inline(m[:strike], style.merge(strike: true)))
          elsif (t = m[:em] || m[:em2]) then out.concat(inline(t, style.merge(italic: true)))
          else
            out.concat(inline(m[:label], style.merge(fg: :blu, underline: true)))
            out << Seg.new(" (#{m[:url]})", style.merge(fg: :tx2)) unless m[:url] == m[:label]
          end
        end
        out << Seg.new(unescape(text[pos..]), style) if pos < text.size
        out
      end

      def unescape(s) = s.gsub(ESCAPE, '\1')

      # Greedy word wrap of styled segments. Words keep their segments together, so
      # "**bold**," does not break before the comma; a word wider than the row is
      # broken at grapheme boundaries.
      def wrap(segs, width)
        words = [[]]
        segs.each do |s|
          s.text.split(/(\s+)/).each do |part|
            next if part.empty?

            if part.match?(/\A\s+\z/) then words << [] unless words.last.empty?
            else words.last << Seg.new(part, s.style)
            end
          end
        end
        rows = [[]]
        used = 0
        words.reject(&:empty?).each do |word|
          w = word.sum { Widgets.cells(it.text) }
          if used.positive? && used + 1 + w > width
            rows << []
            used = 0
          end
          if used.positive?
            rows.last << Seg.new(" ", {})
            used += 1
          end
          if w <= width
            rows.last.concat(word)
            used += w
          else
            word.each do |seg|
              seg.text.each_grapheme_cluster do |g|
                gw = Widgets.cells(g)
                (rows << []; used = 0) if used.positive? && used + gw > width
                rows.last << Seg.new(g, seg.style)
                used += gw
              end
            end
          end
        end
        rows
      end

      # A code line in width-cell pieces (at least one grapheme each, so it ends).
      def chop(line, width)
        pieces = []
        rest = line
        until rest.empty?
          piece = Widgets.head(rest, width)
          piece = rest.each_grapheme_cluster.first if piece.empty?
          pieces << piece
          rest = rest.delete_prefix(piece)
        end
        pieces
      end
    end
  end
end
