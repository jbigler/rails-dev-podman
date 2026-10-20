# frozen_string_literal: true

module Wt
  module Views
    module Dashboard
      # The "Worktrees N · M agents" panel: filter row, column header, one row per
      # visible worktree. Columns follow the tier (SPEC "Worktree list columns"):
      #   wide (⅔, full)  WORKTREE HEAD STACK PR CI SERVICES AGENT NVIM LAST
      #   narrow (½, compact) NVIM dropped, CI joins PR, SERVICES is one summary mark,
      #                   HEAD middle-truncated; LAST only while it still has room.
      module List
        W = Widgets
        D = Dashboard
        CHROME = 4 # borders + filter row + header
        WIDE = [[:mark, 1, ""], [:name, 18, "WORKTREE"], [:head, 30, "HEAD"], [:stack, 6, "STACK"], [:pr, 8, "PR"],
                [:ci, 9, "CI"], [:services, 11, "SERVICES"], [:agent, 13, "AGENT"], [:nvim, 7, "NVIM"]].freeze
        NARROW = [[:mark, 1, ""], [:name, 17, "WORKTREE"], [:stack, 5, "STK"], [:prci, 13, "PR · CI"],
                  [:summary, 2, "SV"], [:agent, 12, "AGENT"]].freeze
        NARROW_HEAD = 26
        MAX_HEAD = 30
        LAST_MIN = 16
        AGENT_COLORS = { permission: :ac, failed: :red, running: :blu, starting: :yel, done: :tx2, offline: :tx2 }.freeze
        SEVERITY = %i[failed exited starting running healthy stopped].freeze

        module_function

        # Panel rows for the visible worktrees, at most `cap` rows tall overall.
        def height(model, cap) = CHROME + model.visible_worktrees.size.clamp(1, [cap - CHROME, 1].max)

        def panel(model, tui, theme, width, rows:)
          w = D.inner(width)
          cols = columns(model.ui.tier, w)
          lines = [filter_line(model, tui, theme, w),
                   D.cells(tui, theme, cols.map { |_, cw, label| [W.span(tui, theme, label, :tx2), cw] })]
          lines.concat(body_rows(model, tui, theme, cols, [rows, 1].max))
          W.panel(tui, theme, title: title(model, tui, theme), accent: true, child: tui.paragraph(text: lines))
        end

        def title(model, tui, theme)
          [W.span(tui, theme, "Worktrees", :ac, bold: true),
           W.span(tui, theme, " #{model.worktrees.size} · #{model.agents_by_urgency.size} agents", :tx2)]
        end

        # [[key, width, label]] for an inner width.
        def columns(tier, width)
          if %i[twothirds full].include?(tier)
            wide_columns(width)
          else
            fixed = NARROW.sum { it[1] + 1 } # each column plus the gap before HEAD
            room = width - fixed
            if room - NARROW_HEAD - 1 >= LAST_MIN
              [*NARROW[0, 2], [:head, NARROW_HEAD, "HEAD"], *NARROW[2..], [:last, room - NARROW_HEAD - 1, "LAST"]]
            else
              [*NARROW[0, 2], [:head, room.clamp(1, MAX_HEAD), "HEAD"], *NARROW[2..]]
            end
          end
        end

        # WIDE by actual width: NVIM and LAST are dropped first; past that HEAD shrinks.
        def wide_columns(width)
          no_nvim = WIDE.reject { it[0] == :nvim }
          [[WIDE, true], [no_nvim, true], [WIDE, false], [no_nvim, false]].each do |cols, last|
            used = cols.sum { it[1] + 1 } - 1
            next unless width >= used + (last ? LAST_MIN + 1 : 0)

            return last ? [*cols, [:last, width - used - 1, "LAST"]] : cols
          end
          room = width - (no_nvim.sum { it[1] + 1 } - 1 - MAX_HEAD)
          no_nvim.map { it[0] == :head ? [:head, room.clamp(1, MAX_HEAD), "HEAD"] : it }
        end

        def filter_line(model, tui, theme, width)
          ui = model.ui
          text = if ui.filter_editing then [W.span(tui, theme, ui.filter, :tx, bg: :bg2), W.span(tui, theme, "▏", :ac, bg: :bg2)]
                 elsif ui.filter.empty? then [W.span(tui, theme, "filter by name, branch, PR…", :tx2, bg: :bg2)]
                 else [W.span(tui, theme, ui.filter, :tx, bg: :bg2)]
                 end
          count = ui.filter.empty? ? [] : [W.span(tui, theme, "#{model.visible_worktrees.size} of #{model.worktrees.size} ", :tx2, bg: :bg2)]
          D.spread(tui, theme, [W.span(tui, theme, " / ", :ac, bg: :bg2, bold: true), *text], count, width, bg: :bg2)
        end

        def body_rows(model, tui, theme, cols, max)
          wts = model.visible_worktrees
          return [W.line(tui, W.span(tui, theme, model.worktrees.empty? ? "  no worktrees" : "  no worktree matches the filter", :tx2))] if wts.empty?

          sel = model.selected_worktree&.slug
          i = wts.index { it.slug == sel } || 0
          first = (i - max + 1).clamp(0, [wts.size - max, 0].max)
          wts[first, max].map { row(model, tui, theme, it, cols, it.slug == sel) }
        end

        def row(model, tui, theme, wt, cols, selected)
          bg = selected ? :sel : nil
          D.cells(tui, theme, cols.map { |key, w, _| [cell(model, tui, theme, wt, key, w, selected), w] }, bg:)
        end

        def cell(model, tui, theme, wt, key, width, selected)
          slug = wt.slug
          case key
          when :mark then [W.span(tui, theme, selected ? "▌" : "", :ac, bold: true)]
          when :name then [W.span(tui, theme, W.truncate(slug, width), :tx, bold: selected)]
          when :head then head(model, tui, theme, wt, width)
          when :stack then stack(model, tui, theme, slug)
          when :pr then pr(model, tui, theme, wt)
          when :ci then ci(model, tui, theme, slug)
          when :prci
            model.failed?("pr", slug) ? [W.unknown(tui, theme)] : [*pr(model, tui, theme, wt), W.span(tui, theme, " "), *ci(model, tui, theme, slug)]
          when :services then services(model, tui, theme, slug)
          when :summary then summary(model, tui, theme, slug)
          when :agent then agent(model, tui, theme, slug)
          when :nvim then nvim(model, tui, theme, slug)
          when :last then last(model, tui, theme, slug)
          end
        end

        # Branch name (or the short sha when detached); middle-truncated below ⅔.
        def head(model, tui, theme, wt, width)
          return [W.unknown(tui, theme)] if model.failed?("git", wt.slug)

          g = model.git[wt.slug]
          name = if g&.detached || wt.detached then "(#{wt.head.to_s[0, 7]})"
                 else g&.branch || wt.branch || "—"
                 end
          text = %i[twothirds full].include?(model.ui.tier) ? W.truncate(name, width) : W.truncate_middle(name, width)
          [W.span(tui, theme, text, :pur)]
        end

        def stack(model, tui, theme, slug)
          return [W.unknown(tui, theme)] if model.failed?("stack", slug)

          st = model.stacks[slug]
          pos = st&.position
          return [W.span(tui, theme, st ? "—" : "", :tx2)] unless pos

          [W.span(tui, theme, "#{pos}/#{st.size}", st.needs_restack ? :yel : :tx)]
        end

        def pr(model, tui, theme, wt)
          return [W.unknown(tui, theme)] if model.failed?("pr", wt.slug)

          case (pr = model.prs[wt.slug])
          when PrStatus then [W.span(tui, theme, "##{pr.number}", pr_color(pr))]
          when :none then [W.span(tui, theme, wt.base ? "—" : "no PR", :tx2)]
          else []
          end
        end

        def pr_color(pr)
          return :tx2 if pr.draft
          return :pur if pr.state == "MERGED"
          return :red if pr.state == "CLOSED"

          { approved: :grn, changes_requested: :red }.fetch(pr.review, :yel)
        end

        def ci(model, tui, theme, slug)
          return [W.unknown(tui, theme)] if model.failed?("pr", slug)

          pr = model.prs[slug]
          return [] unless pr.is_a?(PrStatus)

          case pr.ci
          when :pass then [W.span(tui, theme, "✓", :grn)]
          when :fail then [W.span(tui, theme, "✗ #{pr.ci_failed}", :red)]
          when :pending then [W.span(tui, theme, "⟳ #{pr.ci_passed}/#{pr.ci_total}", :yel)]
          else []
          end
        end

        def units_failed?(model, slug) = model.failures.key?("units") || model.failed?("units", slug)

        # Every service in Service::NAMES order; units not reported yet count as stopped.
        def service_list(model, slug)
          list = model.services[slug] || []
          Service::NAMES.map { |name| list.find { it.name == name } || Service.new(name:) }
        end

        def services(model, tui, theme, slug)
          return [W.unknown(tui, theme)] if units_failed?(model, slug)

          glyphs = model.services.key?(slug) ? service_list(model, slug).map { W.glyph(tui, theme, it.state) } : []
          # A running up/stop/restart: keep the glyphs (they show containers arriving) and say what is under way.
          busy = model.busy[slug]
          busy ? [*glyphs, W.span(tui, theme, "#{' ' unless glyphs.empty?}⟳ #{busy.label}", :yel)] : glyphs
        end

        # One mark for the whole pod: the most severe service state, or ⟳ while an action runs.
        def summary(model, tui, theme, slug)
          return [W.unknown(tui, theme)] if units_failed?(model, slug)
          return [W.span(tui, theme, "⟳", :yel)] if model.busy[slug]
          return [] unless model.services.key?(slug)

          states = service_list(model, slug).map(&:state)
          [W.glyph(tui, theme, SEVERITY.find { states.include?(it) } || :stopped)]
        end

        def agent(model, tui, theme, slug)
          state = model.agent_state(slug)
          return [W.span(tui, theme, "—", :tx2)] unless state

          [W.span(tui, theme, "#{Theme::GLYPHS.fetch(state)} #{Session.agent_name(model, slug) || 'agent'}", AGENT_COLORS.fetch(state, :tx2))]
        end

        def nvim(model, tui, theme, slug)
          return [W.unknown(tui, theme)] if model.failed?("nvim", slug)

          n = model.nvim[slug]
          return [] unless n

          n.running ? [W.glyph(tui, theme, :running, n.ui_count.to_s)] : [W.glyph(tui, theme, :stopped)]
        end

        # The ACP session's newest event, else the status file's `last`.
        def last(model, tui, theme, slug)
          state = model.agent_state(slug)
          color = { permission: :ac, failed: :red }.fetch(state, :tx2)
          text = last_text(model, slug)
          text ? [W.span(tui, theme, text, color)] : []
        end

        def last_text(model, slug)
          s = Session.live(model, slug)
          if s
            return "permission: #{s.permission.title}" if s.permission
            return s.error.to_s if s.error

            call = s.tool_calls.last
            msg = s.transcript.reverse.find { it.role != :user }
            pick = if call && msg && call.at.is_a?(Time) && msg.at.is_a?(Time) then call.at >= msg.at ? call : msg
                   else call || msg
                   end
            case pick
            when ToolCall then return "#{pick.kind} #{pick.title}"
            when TranscriptEntry then return pick.text.to_s.lines.first&.chomp
            end
          end
          model.agents[slug]&.last
        end
      end
    end
  end
end
