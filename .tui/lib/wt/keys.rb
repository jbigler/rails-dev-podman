# frozen_string_literal: true

module Wt
  # Turns a RatatuiRuby key event into an action. Modal states are checked first,
  # in this order: confirm dialog, text prompt, filter, reply input, help overlay.
  module Keys
    def self.normalize(event)
      code = event.code.to_s
      mods = event.modifiers.map(&:to_s) - (code.length == 1 ? ["shift"] : [])
      mods.empty? ? code : "#{mods.sort.join('+')}+#{code}"
    end

    def self.handle(event, model)
      key = normalize(event)
      ui = model.ui
      return confirm(key, model) if ui.confirm
      return prompt(key, event, model) if ui.prompt
      return filter(key, event, model) if ui.filter_editing
      return input(key, event, model) if ui.input_focus
      return model.with(ui: ui.with(help: false)) if ui.help && %w[? esc q].include?(key)

      binding = Keymap.lookup(key, ui.screen)
      return model unless binding

      dispatch(model, binding.action, *binding.args, key:)
    end

    # Actions that take the pressed key (move, jump_agent, answer_permission) receive it as `key:`.
    def self.dispatch(model, action, *args, key: nil)
      return model.notify("#{action}: not available", level: :error) unless Actions.respond_to?(action)

      params = Actions.method(action).parameters
      if params.any? { |type, name| name == :key && %i[key keyreq].include?(type) }
        Actions.public_send(action, model, *args, key:)
      else
        Actions.public_send(action, model, *args)
      end
    end

    def self.confirm(key, model)
      c = model.ui.confirm
      model = model.with(ui: model.ui.with(confirm: nil))
      key == "y" ? Actions.public_send(c.action, model, *c.args) : model
    end

    def self.prompt(key, event, model)
      p = model.ui.prompt
      case key
      when "esc" then model.with(ui: model.ui.with(prompt: nil))
      when "enter"
        model = model.with(ui: model.ui.with(prompt: nil))
        p.text.strip.empty? ? model : Actions.public_send(p.action, model, p.text.strip, *p.args)
      when "backspace" then model.with(ui: model.ui.with(prompt: p.with(text: p.text[0...-1])))
      else
        ch = printable(event)
        ch ? model.with(ui: model.ui.with(prompt: p.with(text: p.text + ch))) : model
      end
    end

    def self.filter(key, event, model)
      ui = model.ui
      case key
      when "esc" then model.with(ui: ui.with(filter: "", filter_editing: false))
      when "enter" then model.with(ui: ui.with(filter_editing: false))
      when "backspace" then model.with(ui: ui.with(filter: ui.filter[0...-1]))
      else
        ch = printable(event)
        ch ? model.with(ui: ui.with(filter: ui.filter + ch)) : model
      end
    end

    # Reply input (dashboard agent panel and chat). Digits answer a pending
    # permission while the input is empty; a typed reply rejects and sends.
    def self.input(key, event, model)
      ui = model.ui
      case key
      when "esc" then model.with(ui: ui.with(input_focus: false))
      when "ctrl+]" then dispatch(model, :leave_chat)
      when "enter" then dispatch(model, :send_input)
      when "backspace" then model.with(ui: ui.with(input: ui.input[0...-1]))
      when "1", "2", "3"
        if ui.input.empty? && model.permission_for(model.focus_slug)
          dispatch(model, :answer_permission, key:)
        else
          model.with(ui: ui.with(input: ui.input + key))
        end
      else
        ch = printable(event)
        return model.with(ui: ui.with(input: ui.input + ch)) if ch

        # Non-text keys (F1–F3, Tab, ^b, ^o, arrows…) keep working while typing.
        binding = Keymap.lookup(key, ui.screen)
        binding ? dispatch(model, binding.action, *binding.args, key:) : model
      end
    end

    def self.printable(event)
      return " " if event.code.to_s == "space"

      s = event.to_s
      s.length == 1 && (event.modifiers.map(&:to_s) - ["shift"]).empty? ? s : nil
    end
  end
end
