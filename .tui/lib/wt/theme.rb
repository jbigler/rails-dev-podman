# frozen_string_literal: true

module Wt
  # Flexoki palettes, copied from the PAL object in docs/design/screens/*.dc.html.
  # Views never name a hex colour: they ask the theme for a role.
  class Theme < Data.define(:name, :accent_name, :colors)
    PALETTES = {
      light: { bg: "#FFFCF0", bg2: "#F2F0E5", sel: "#E6E4D9", ui: "#CECDC3", ui2: "#B7B5AC", tx: "#100F0F", tx2: "#6F6E69",
               red: "#AF3029", ora: "#BC5215", yel: "#8E6B01", grn: "#536907", cyn: "#1C6C66", blu: "#205EA6", pur: "#5E409D", mag: "#A02F6F" }.freeze,
      dark: { bg: "#100F0F", bg2: "#1C1B1A", sel: "#282726", ui: "#403E3C", ui2: "#575653", tx: "#CECDC3", tx2: "#878580",
              red: "#D14D41", ora: "#DA702C", yel: "#D0A215", grn: "#879A39", cyn: "#3AA99F", blu: "#4385BE", pur: "#8B7EC8", mag: "#CE5D97" }.freeze
    }.freeze
    ACCENT_KEYS = { orange: :ora, cyan: :cyn, purple: :pur, blue: :blu }.freeze

    # State glyphs: states are never told apart by colour alone.
    GLYPHS = {
      permission: "◆", failed: "✗", running: "●", done: "·", starting: "◐", stopped: "○",
      healthy: "●", working: "●", waiting: "·", offline: "○", exited: "✗"
    }.freeze
    # Tool call kinds → glyph (colour via #kind_color).
    KIND_GLYPHS = { "read" => "◇", "search" => "⌕", "edit" => "✎", "delete" => "✎", "move" => "✎",
                    "execute" => "$", "fetch" => "◇", "think" => "·", "other" => "·" }.freeze

    def self.for(name, accent = :orange)
      colors = PALETTES.fetch(name).merge(ac: PALETTES.fetch(name).fetch(ACCENT_KEYS.fetch(accent, :ora)))
      new(name:, accent_name: accent, colors: colors.freeze)
    end

    def [](role) = colors.fetch(role)

    # A RatatuiRuby style. fg/bg are palette roles (:tx, :ac, ...).
    def style(fg = :tx, bg: nil, bold: false, dim: false, reverse: false, italic: false, underline: false, strike: false)
      mods = []
      mods << :bold if bold
      mods << :dim if dim
      mods << :reversed if reverse
      mods << :italic if italic
      mods << :underlined if underline
      mods << :crossed_out if strike
      RatatuiRuby::Style::Style.new(fg: fg && self[fg], bg: bg && self[bg], modifiers: mods)
    end

    # Colour role for a state symbol (service, agent or tool call state).
    def state_color(state)
      case state
      when :running, :healthy, :completed, :pass, :done then :grn
      when :starting, :pending, :in_progress, :working then :yel
      when :failed, :exited, :fail then :red
      when :permission, :waiting_permission then :ac
      else :tx2
      end
    end

    def kind_color(kind)
      case kind
      when "read", "search", "fetch" then :cyn
      when "edit", "delete", "move" then :pur
      when "execute" then :blu
      else :tx2
      end
    end
  end
end
