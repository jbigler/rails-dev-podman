# frozen_string_literal: true

module Wt
  module Views
    module Dashboard
      # "wt/<slug>": branch with ahead/behind and dirty count, the PR with its checks,
      # then the gh stack as a tree from trunk to the top branch, HEAD marked.
      module Branch
        W = Widgets
        D = Dashboard
        REVIEW = { approved: ["approved", :grn], changes_requested: ["changes", :red], review_required: ["review", :yel] }.freeze
        CI = { pass: ["✓", :grn], fail: ["✗", :red], pending: ["⟳", :yel] }.freeze
        TREE_COLS = [9, 8, 7].freeze # review, ci, ◀ HEAD

        module_function

        # [widget, rows]
        def panel(model, tui, theme, slug, width)
          w = D.inner(width)
          wt = model.worktree(slug)
          lines = [branch_line(model, tui, theme, wt, w), *pr_lines(model, tui, theme, wt, w), D.rule(tui, theme, w),
                   *stack_lines(model, tui, theme, slug, w), hints(model, tui, theme, slug)]
          [W.panel(tui, theme, title: [W.span(tui, theme, "wt/#{slug}", :tx, bold: true)], child: tui.paragraph(text: lines)),
           lines.size + 2]
        end

        def branch_line(model, tui, theme, wt, width)
          return W.line(tui, W.span(tui, theme, "⎇ #{wt.branch} ", :pur), W.unknown(tui, theme)) if model.failed?("git", wt.slug)

          g = model.git[wt.slug]
          name = g&.detached || wt.detached ? "(detached #{wt.head.to_s[0, 7]})" : (g&.branch || wt.branch || "—")
          info = g ? "↑#{g.ahead} ↓#{g.behind} · #{g.dirty.zero? ? 'clean' : "#{g.dirty} uncommitted"}" : ""
          tui.line(spans: D.fit(tui, theme, [W.span(tui, theme, "⎇ #{name}", :pur), W.span(tui, theme, "  #{info}", :tx2)], width))
        end

        def pr_lines(model, tui, theme, wt, width)
          return [W.line(tui, W.span(tui, theme, "PR ", :tx2), W.unknown(tui, theme))] if model.failed?("pr", wt.slug)

          pr = model.prs[wt.slug]
          case pr
          when PrStatus
            [D.spread(tui, theme, [W.span(tui, theme, "##{pr.number} ", :blu), W.span(tui, theme, pr.title, :tx)], badges(tui, theme, pr), width),
             tui.line(spans: D.fit(tui, theme, checks(tui, theme, pr), width))]
          when :none then [W.line(tui, W.span(tui, theme, "no PR for this branch", :tx2))]
          else [W.line(tui, W.span(tui, theme, "PR …", :tx2))]
          end
        end

        def badges(tui, theme, pr)
          label = if pr.state == "MERGED" then ["MERGED", :pur]
                  elsif pr.state == "CLOSED" then ["CLOSED", :red]
                  elsif pr.draft then ["DRAFT", :tx2]
                  end
          label ? [tui.span(content: " #{label[0]} ", style: theme.style(:bg, bg: label[1], bold: true))] : []
        end

        def checks(tui, theme, pr)
          case pr.ci
          when :fail
            [W.span(tui, theme, "✗ #{pr.ci_failed} failing", :red), W.span(tui, theme, " #{pr.failing.join(', ')}", :tx2),
             (W.span(tui, theme, "  ✓ #{pr.ci_passed} passed", :grn) if pr.ci_passed.positive?)]
          when :pending then [W.span(tui, theme, "⟳ #{pr.ci_passed}/#{pr.ci_total} checks passed, rest running", :yel)]
          when :pass then [W.span(tui, theme, "✓ #{pr.ci_passed} passed", :grn)]
          else [W.span(tui, theme, "no checks", :tx2)]
          end
        end

        def stack_lines(model, tui, theme, slug, width)
          return [W.line(tui, W.span(tui, theme, "gh stack ", :tx2), W.unknown(tui, theme))] if model.failed?("stack", slug)

          st = model.stacks[slug]
          return [W.line(tui, W.span(tui, theme, "gh stack …", :tx2))] unless st
          return [W.line(tui, W.span(tui, theme, "gh stack · not stacked", :tx2))] if st.entries.empty?

          hint = st.needs_restack ? [W.span(tui, theme, "⟳ needs restack", :yel)] : []
          header = D.spread(tui, theme, [W.span(tui, theme, "gh stack · #{st.size} branches", :tx2)], hint, width)
          [header, W.line(tui, W.span(tui, theme, st.trunk, :tx2)),
           *st.entries.each_with_index.map { |e, i| entry(model, tui, theme, slug, e, i, width) }]
        end

        def entry(model, tui, theme, slug, e, depth, width)
          bg = e.head ? :sel : nil
          name_w = width - TREE_COLS.sum - TREE_COLS.size
          name = [W.span(tui, theme, "#{'   ' * depth}└─ ", :tx2),
                  W.span(tui, theme, [("##{e.number}" if e.number), e.branch].compact.join(" "), :tx, bold: e.head)]
          review = e.draft ? ["draft", :tx2] : REVIEW[e.review]
          D.cells(tui, theme, [
            [name, name_w],
            [review ? [W.span(tui, theme, review[0], review[1])] : [], TREE_COLS[0]],
            [ci(model, tui, theme, slug, e), TREE_COLS[1]],
            [e.head ? [W.span(tui, theme, "◀ HEAD", :ac, bold: true)] : [], TREE_COLS[2]]
          ], bg:)
        end

        # Entry CI glyph; the worktree's own PR adds its counts ("✗ 2", "⟳ 14/15").
        def ci(model, tui, theme, slug, e)
          g, color = CI[e.ci]
          return [] unless g

          pr = model.prs[slug]
          count = if pr.is_a?(PrStatus) && pr.number == e.number
                    { fail: " #{pr.ci_failed}", pending: " #{pr.ci_passed}/#{pr.ci_total}" }[e.ci]
                  end
          [W.span(tui, theme, "#{g}#{count}", color)]
        end

        def hints(model, tui, theme, slug)
          restack = model.stacks[slug]&.needs_restack
          W.line(tui, *D.chip(tui, theme, "[ ]", "down/up"), *D.chip(tui, theme, "R", "restack", bg: restack ? :yel : :tx2),
                 *D.chip(tui, theme, "P", "push stack"), *D.chip(tui, theme, "p", "open PR"))
        end
      end
    end
  end
end
