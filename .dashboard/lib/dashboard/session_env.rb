# frozen_string_literal: true

module Dashboard
  # The desktop session's variables an action child needs, read from the user
  # manager at every start: the service's own environment is whatever it started
  # with (at boot, or before a re-login), and `mise run dashboard` pushes the
  # current ones there. Unset ones stay unset.
  module SessionEnv
    KEYS = %w[SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR KITTY_LISTEN_ON].freeze
    ESCAPES = { "n" => "\n", "t" => "\t", "\\" => "\\", "'" => "'", '"' => '"' }.freeze

    # → Hash: the KEYS the manager has, plus NO_COLOR=1. A failed read gives NO_COLOR alone.
    def self.current
      r = Shell.run(%w[systemctl --user show-environment])
      (r.ok? ? parse(r.stdout) : {}).slice(*KEYS).merge("NO_COLOR" => "1")
    end

    # `KEY=value` lines; systemd writes a value with special characters as $'…' with backslash escapes.
    def self.parse(text)
      text.each_line(chomp: true).filter_map do |line|
        key, value = line.split("=", 2)
        next unless value

        value = value[2..-2].gsub(/\\(.)/) { ESCAPES.fetch($1, $1) } if value.start_with?("$'") && value.end_with?("'") && value.size > 2
        [key, value]
      end.to_h
    end
  end
end
