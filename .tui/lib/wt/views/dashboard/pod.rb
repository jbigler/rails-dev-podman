# frozen_string_literal: true

module Wt
  module Views
    module Dashboard
      # "Pod <prefix>-<slug>": the agent and nvim rows with their keys, then the
      # services table (state from the units, CPU/MEM from podman stats).
      module Pod
        W = Widgets
        D = Dashboard
        HEAD = [7, 15].freeze # label, detail columns of the agent / nvim rows
        TABLE = [[11, "SERVICE"], [12, "STATE"], [7, "PORT"], [6, "CPU"], [6, "MEM"]].freeze
        PORTS = { "rails" => :app_port, "db" => :db_port, "rustfs" => :s3_port, "playwright" => :playwright_port }.freeze
        AGENT_TEXT = { permission: ["awaiting permission", :ac], failed: ["failed", :red], running: ["working", :blu],
                       starting: ["starting", :yel], done: ["waiting for you", :tx2], offline: ["offline", :tx2] }.freeze

        module_function

        # [widget, rows]
        def panel(model, tui, theme, slug, width)
          w = D.inner(width)
          wt = model.worktree(slug)
          lines = [*agent_rows(model, tui, theme, slug, w), *nvim_rows(model, tui, theme, wt, w), D.rule(tui, theme, w),
                   *table(model, tui, theme, wt, w)]
          title = [W.span(tui, theme, "Pod", :tx, bold: true), W.span(tui, theme, " #{model.config.prefix}-#{slug}", :tx2)]
          [W.panel(tui, theme, title:, child: tui.paragraph(text: lines)), lines.size + 2]
        end

        def head_row(tui, theme, label, detail, rest, width)
          D.cells(tui, theme, [[[W.span(tui, theme, label)], HEAD[0]], [detail, HEAD[1]], [rest, [width - HEAD.sum - 2, 0].max]])
        end

        def agent_rows(model, tui, theme, slug, width)
          name = Session.agent_name(model, slug)
          detail = name ? [W.span(tui, theme, "#{name}#{' · ACP' if Session.live(model, slug)}", :tx2)] : [W.span(tui, theme, "—", :tx2)]
          state = model.agent_state(slug)
          text, color = AGENT_TEXT.fetch(state, ["no agent", :tx2])
          err = model.sessions[slug]&.error if state == :failed
          status = [W.span(tui, theme, "#{Theme::GLYPHS.fetch(state || :offline)} #{text}", color), (W.span(tui, theme, " · #{err}", :red) if err)]
          [head_row(tui, theme, "agent", detail, status, width),
           head_row(tui, theme, "", [], [*D.chip(tui, theme, "a", "chat", bg: :ac), *D.chip(tui, theme, "A", "new session")], width)]
        end

        def nvim_rows(model, tui, theme, wt, width)
          port = [W.span(tui, theme, wt.nvim_port ? ":#{wt.nvim_port}" : "—", :tx2)]
          n = model.nvim[wt.slug]
          status = if model.failed?("nvim", wt.slug) then [W.unknown(tui, theme)]
                   elsif n.nil? then [W.span(tui, theme, "—", :tx2)]
                   elsif n.running
                     [W.glyph(tui, theme, :running), W.span(tui, theme, " listening · #{n.ui_count} UI · #{n.buffers} buffers"),
                      (W.span(tui, theme, " · #{n.modified} modified", :yel) if n.modified.to_i.positive?),
                      (W.span(tui, theme, " · #{File.basename(n.file)}", :tx2) if n.file && !n.file.empty?)]
                   else [W.glyph(tui, theme, :stopped, "stopped")]
                   end
          [head_row(tui, theme, "nvim", port, status, width),
           head_row(tui, theme, "", [], [*D.chip(tui, theme, "n", "attach here"), *D.chip(tui, theme, "N", "new window")], width)]
        end

        def table(model, tui, theme, wt, width)
          up_w = [width - TABLE.sum { it[0] + 1 }, 0].max
          header = D.cells(tui, theme, [*TABLE.map { |w, label| [[W.span(tui, theme, label, :tx2)], w] }, [[W.span(tui, theme, "UP", :tx2)], up_w]])
          [header, *List.service_list(model, wt.slug).map { service_row(model, tui, theme, wt, it, up_w) }]
        end

        def service_row(model, tui, theme, wt, svc, up_w)
          units_failed = List.units_failed?(model, wt.slug)
          stats_failed = model.failed?("stats", wt.slug)
          stats = model.stats[wt.slug]&.[](model.config.container_name(svc.name, wt.slug))
          up = svc.up? || svc.state == :starting
          port = svc.port || (m = PORTS[svc.name]) && wt.public_send(m)
          state = units_failed ? [W.unknown(tui, theme)] : [W.glyph(tui, theme, svc.state, svc.state.to_s), (W.span(tui, theme, " #{svc.detail}", :tx2) if svc.detail && !svc.up?)]
          dash = [W.span(tui, theme, "—", :tx2)]
          cpu, mem = if stats_failed && up then [[W.unknown(tui, theme)]] * 2
                     elsif stats && up then [[W.span(tui, theme, stats.cpu ? format("%.1f%%", stats.cpu) : "—")], [W.span(tui, theme, bytes(stats.mem))]]
                     else [dash, dash]
                     end
          uptime = up && svc.started_at.is_a?(Time) ? W.duration(model.now - svc.started_at) : "—"
          D.cells(tui, theme, [
            [[W.span(tui, theme, svc.label)], TABLE[0][0]],
            [state, TABLE[1][0]],
            [[W.span(tui, theme, up && port ? ":#{port}" : "—", :tx2)], TABLE[2][0]],
            [cpu, TABLE[3][0]], [mem, TABLE[4][0]],
            [[W.span(tui, theme, uptime, :tx2)], up_w]
          ])
        end

        # 627048448 → "598M", 2.5 GiB → "2.5G"
        def bytes(n)
          return "—" unless n

          mib = n / 1_048_576.0
          if mib < 1 then "#{(n / 1024.0).round}K"
          elsif mib < 1024 then "#{mib.round}M"
          else format("%.1fG", mib / 1024)
          end
        end
      end
    end
  end
end
