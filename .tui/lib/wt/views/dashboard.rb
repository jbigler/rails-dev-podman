# frozen_string_literal: true

module Wt
  module Views
    # PLACEHOLDER until the Dashboard screen lands.
    module Dashboard
      def self.view(model, tui, theme) = tui.paragraph(text: "Dashboard", style: theme.style(:tx))
    end
  end
end
