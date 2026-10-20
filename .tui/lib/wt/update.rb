# frozen_string_literal: true

module Wt
  # message → Model | [Model, command]. wt's own messages fold themselves in
  # (Message#apply); terminal events go to Keys or adjust the UI state.
  module Update
    def self.call(msg, model)
      if msg.is_a?(Message) then msg.apply(model)
      elsif msg.respond_to?(:key?) && msg.key? then Keys.handle(msg, model)
      elsif msg.respond_to?(:resize?) && msg.resize?
        model.with(ui: model.ui.with(width: msg.width, height: msg.height))
      elsif msg.respond_to?(:focus_gained?) && msg.focus_gained? then model.with(ui: model.ui.with(focused: true))
      elsif msg.respond_to?(:focus_lost?) && msg.focus_lost? then model.with(ui: model.ui.with(focused: false))
      elsif msg.respond_to?(:paste?) && msg.paste? then paste(msg, model)
      else model
      end
    end

    def self.paste(msg, model)
      ui = model.ui
      text = msg.content.to_s.tr("\r\n", "  ")
      if ui.prompt then model.with(ui: ui.with(prompt: ui.prompt.with(text: ui.prompt.text + text)))
      elsif ui.input_focus then model.with(ui: ui.with(input: ui.input + text))
      elsif ui.filter_editing then model.with(ui: ui.with(filter: ui.filter + text))
      else model
      end
    end
  end
end
