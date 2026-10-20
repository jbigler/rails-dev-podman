# frozen_string_literal: true

module Wt
  # A transient message in the bottom-right corner. level: :info | :error
  class Toast < Data.define(:id, :text, :level)
    def initialize(id:, text:, level: :info)
      super
    end
  end

  # A yes/no question blocking every other key. On `y`, Actions.public_send(action, model, *args).
  class Confirm < Data.define(:prompt, :action, :args)
    def initialize(prompt:, action:, args: [])
      super
    end
  end

  # A one-line text prompt (e.g. the branch for `c`). On ⏎, Actions.public_send(action, model, text, *args).
  class Prompt < Data.define(:label, :text, :action, :args)
    def initialize(label:, action:, text: "", args: [])
      super
    end
  end

  # Everything about what the person is looking at, as opposed to what is true
  # about the world.
  #   screen:       :worktrees | :agents | :chat
  #   tool_index:   selected tool call in the focused agent session (o / d target)
  #   detail:       compact tier: false = list pane, true = detail pane
  #   input:        reply text being typed (dashboard agent panel and chat share it)
  #   input_focus:  typed characters go to `input` instead of the key map
  class Ui < Data.define(
    :screen, :selected, :width, :height, :theme, :accent,
    :filter, :filter_editing, :agents_view, :agents_index, :chat_slug, :sidebar,
    :input, :input_focus, :tool_index, :detail, :help, :confirm, :prompt, :toasts,
    :focused, :log_service, :next_toast_id
  )
    def initialize(
      screen: :worktrees, selected: nil, width: 187, height: 70, theme: :light, accent: :orange,
      filter: "", filter_editing: false, agents_view: :cards, agents_index: 0, chat_slug: nil, sidebar: true,
      input: "", input_focus: false, tool_index: nil, detail: false, help: false, confirm: nil, prompt: nil,
      toasts: [], focused: true, log_service: "rails", next_toast_id: 1
    )
      super
    end

    def tier = Tier.for(width)
  end
end
