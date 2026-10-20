# frozen_string_literal: true

module Wt
  module Views
    # PLACEHOLDER until the Agents screen lands.
    module Agents
      def self.view(model, tui, theme) = tui.paragraph(text: "Agents", style: theme.style(:tx))
    end
  end
end
