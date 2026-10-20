# frozen_string_literal: true

module Wt
  # Width tiers matching niri columns on 2560×1440 (SPEC "Screens, layout tiers and keys").
  module Tier
    ORDER = %i[compact half twothirds full].freeze

    def self.for(columns)
      if columns < 100 then :compact
      elsif columns < 150 then :half
      elsif columns < 220 then :twothirds
      else :full
      end
    end

    # The ⅔-tier label in the top bar ("187×70 · ⅔").
    LABELS = { compact: "compact", half: "½", twothirds: "⅔", full: "full" }.freeze
  end
end
