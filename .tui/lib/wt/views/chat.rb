# frozen_string_literal: true

module Wt
  module Views
    # PLACEHOLDER until the Chat screen lands.
    module Chat
      def self.view(model, tui, theme) = tui.paragraph(text: "Chat", style: theme.style(:tx))
    end
  end
end
