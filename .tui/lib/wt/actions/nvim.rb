# frozen_string_literal: true

module Wt
  # nvim keys (SPEC "nvim integration"); the target is always model.focus_slug.
  module Actions
    # n — hand the terminal to `mise run nvim` in the worktree; on return the
    # next frame redraws, and the nvim status is refetched (UI count changed).
    def self.nvim_here(model)
      wt = model.worktree(model.focus_slug)
      return model.notify("nvim: no worktree selected", level: :error) unless wt

      status = Terminal.handover(%w[mise run nvim], chdir: wt.path)
      model, refresh = Refresh.schedule(model, [nvim_status_spec(model, wt)].compact)
      return refresh ? [model, refresh] : model if status == 0

      model, toast = model.notify("nvim: mise run nvim #{status ? "exited #{status}" : 'did not start'}", level: :error)
      [model, Rooibos::Command.batch(*[toast, refresh].compact)]
    end

    # N — a new OS window attached to the worktree's nvim: kitty, then
    # $TERMINAL -e, then (nothing can open a window) n.
    def self.nvim_window(model)
      wt = model.worktree(model.focus_slug)
      return model.notify("nvim: no worktree selected", level: :error) unless wt

      launchers = Nvim.window_launchers(wt.path)
      return nvim_here(model) if launchers.empty?

      [model, Nvim::LaunchWindow.new(label: "nvim window", slug: wt.slug, cwd: wt.path.dup.freeze,
                                     launchers: Ractor.make_shareable(launchers), timeout: model.config.timeout)]
    end

    # o / ^o — the selected tool call's file at its line.
    def self.open_tool_call(model)
      nvim_tool_call_target(model, "open") do |wt, path, line|
        label = "open #{Nvim.display_path(path)}#{":#{line}" if line}"
        nvim_drive(model, wt, label, Nvim.open_expr(path, line))
      end
    end

    # d (chat) — the selected edit's file, diffed against HEAD.
    def self.show_diff(model)
      nvim_tool_call_target(model, "diff", prefer_kind: "edit") do |wt, path, line|
        nvim_drive(model, wt, "diff #{Nvim.display_path(path)}", Nvim.diff_expr(path, line))
      end
    end

    # Resolves the focused worktree's selected tool call (nil index: the latest
    # one with a location, of `prefer_kind` when there is one) to a container
    # path; yields (worktree, path, line) or returns the toast explaining why not.
    def self.nvim_tool_call_target(model, verb, prefer_kind: nil)
      slug = model.focus_slug
      wt = model.worktree(slug)
      return model.notify("#{verb}: no worktree selected", level: :error) unless wt
      return model.notify("#{verb}: no nvim port for #{slug}", level: :error) unless wt.nvim_port

      calls = model.sessions[slug]&.tool_calls || []
      located = calls.select { nvim_location(it) }
      call = if model.ui.tool_index then calls[model.ui.tool_index]
             else located.reverse.find { it.kind == prefer_kind } || located.last
             end
      loc = call && nvim_location(call)
      return model.notify("#{verb}: no tool call with a file location", level: :error) unless loc

      host_path, line = loc
      path = Nvim.container_path(model.config, slug, host_path)
      return model.notify("#{verb}: #{host_path} is outside the #{slug} worktree", level: :error) unless path

      yield wt, path, line
    end

    # First location of a tool call as [path, line] (line nil when absent).
    def self.nvim_location(call)
      loc = call.locations.first
      return nil unless loc.respond_to?(:[])

      path = loc[:path] || loc["path"]
      line = loc[:line] || loc["line"]
      path.is_a?(String) && !path.empty? ? [path, line.is_a?(Integer) ? line : nil] : nil
    end

    # Delivers an expression to the worktree's nvim. With no UI attached the
    # file would open unseen, so a window opens too (Drive waits for its
    # server); with no way to open a window, wt attaches here first and the
    # expression is sent by a command afterwards — never blocking update — so
    # the file is waiting the next time nvim is attached.
    def self.nvim_drive(model, wt, label, expression)
      attached = model.nvim[wt.slug]&.ui_count.to_i.positive?
      launchers = attached ? [] : Nvim.window_launchers(wt.path)
      drive = Nvim::Drive.new(label: label.freeze, slug: wt.slug, port: wt.nvim_port, payload: expression.freeze,
                              cwd: wt.path.dup.freeze, launchers: Ractor.make_shareable(launchers),
                              timeout: model.config.timeout)
      return [model, drive] if attached || !launchers.empty?

      model, cmd = Rooibos.normalize_init(nvim_here(model))
      model, toast = model.notify("#{label}: sent to nvim; press n to see it")
      [model, Rooibos::Command.batch(*[cmd, drive, toast].compact)]
    end

    def self.nvim_status_spec(model, wt)
      ["nvim:#{wt.slug}", Sources::Nvim, model.config, wt.slug, wt.nvim_port] if wt.nvim_port
    end

    private_class_method :nvim_tool_call_target, :nvim_location, :nvim_drive, :nvim_status_spec
  end
end
