# frozen_string_literal: true

module Wt
  # One method per Keymap action: (model, *args, [key:]) → Model | [Model, command].
  # Split by domain across actions/*.rb; this file holds screen and selection moves.
  module Actions
    SCREENS = %i[worktrees agents chat].freeze

    def self.show_screen(model, screen)
      ui = model.ui
      chat_slug = screen == :chat ? (ui.chat_slug || model.focus_slug) : ui.chat_slug
      model.with(ui: ui.with(screen:, chat_slug:, input_focus: screen == :chat && !chat_slug.nil?, help: false, tool_index: nil))
    end

    def self.next_screen(model) = show_screen(model, SCREENS[(SCREENS.index(model.ui.screen) + 1) % SCREENS.size])

    def self.move(model, key:)
      delta = %w[up k].include?(key) ? -1 : 1
      ui = model.ui
      case ui.screen
      when :worktrees
        rows = model.visible_worktrees.map(&:slug)
        return model if rows.empty?

        i = rows.index(ui.selected) || 0
        model.with(ui: ui.with(selected: rows[(i + delta).clamp(0, rows.size - 1)], tool_index: nil))
      when :agents
        n = model.agents_by_urgency.size
        n.zero? ? model : model.with(ui: ui.with(agents_index: (ui.agents_index + delta).clamp(0, n - 1)))
      else move_tool_call(model, key: delta.negative? ? "{" : "}")
      end
    end

    # { / } — previous / next tool call of the focused session (the o / d target).
    # nil index means "follow the latest".
    def self.move_tool_call(model, key:)
      calls = model.sessions[model.focus_slug]&.tool_calls || []
      return model if calls.empty?

      i = model.ui.tool_index || calls.size
      i = (i + (key == "{" ? -1 : 1))
      model.with(ui: model.ui.with(tool_index: i >= calls.size ? nil : i.clamp(0, calls.size - 1)))
    end

    def self.open(model)
      ui = model.ui
      if ui.screen == :worktrees && ui.tier == :compact && !ui.detail
        model.with(ui: ui.with(detail: true))
      elsif ui.screen == :agents
        slug = model.focus_slug
        slug ? Keys.dispatch(model.with(ui: ui.with(selected: slug)), :chat) : model
      else
        Keys.dispatch(model, :chat)
      end
    end

    def self.back(model)
      ui = model.ui
      if ui.help then model.with(ui: ui.with(help: false))
      elsif ui.detail then model.with(ui: ui.with(detail: false))
      elsif ui.screen == :chat then leave_chat(model)
      elsif !ui.filter.empty? then model.with(ui: ui.with(filter: ""))
      else model
      end
    end

    def self.start_filter(model) = model.with(ui: model.ui.with(filter_editing: true))

    def self.toggle_agents_view(model)
      model.with(ui: model.ui.with(agents_view: model.ui.agents_view == :cards ? :list : :cards))
    end

    def self.jump_agent(model, key:)
      i = key.delete_prefix("ctrl+").to_i - 1
      i < model.agents_by_urgency.size ? model.with(ui: model.ui.with(agents_index: i)) : model
    end

    def self.focus_input(model) = model.focus_slug ? model.with(ui: model.ui.with(input_focus: true)) : model

    def self.leave_chat(model)
      ui = model.ui
      model.with(ui: ui.with(screen: :worktrees, selected: ui.chat_slug || ui.selected, input_focus: false, tool_index: nil))
    end

    def self.toggle_sidebar(model) = model.with(ui: model.ui.with(sidebar: !model.ui.sidebar))
    def self.toggle_theme(model) = model.with(ui: model.ui.with(theme: model.ui.theme == :light ? :dark : :light))
    def self.toggle_help(model) = model.with(ui: model.ui.with(help: !model.ui.help))
    def self.quit(model) = [model, Rooibos::Command.exit]
  end
end
