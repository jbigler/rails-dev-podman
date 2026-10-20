# frozen_string_literal: true

module Wt
  module Sources
    # The nvim server's state for the pod panel, in one --remote-expr round trip.
    # A refused port (server down) or a host without nvim is a fact, not a
    # failure: NvimStatus(running: false) draws `○ stopped`.
    module Nvim
      STOPPED = NvimStatus.new(running: false, ui_count: nil)

      # A method, not a constant: sources/ loads before nvim/ (Wt::LAYERS).
      def self.status_expr
        "json_encode({'uis': len(nvim_list_uis()), " \
          "'buffers': len(getbufinfo({'buflisted': 1})), " \
          "'modified': len(#{Wt::Nvim::MODIFIED}), " \
          "'file': expand('%:p'), 'line': line('.')})"
      end

      def self.fetch(config, slug, port)
        r = Wt::Nvim.expr(port, status_expr, timeout: config.timeout)
        status =
          if Wt::Nvim.unreachable?(r) then STOPPED
          elsif r.ok? then parse(r.stdout)
          else raise Error, "nvim --remote-expr: #{r.error_line}"
          end
        Msg::NvimLoaded.new(slug:, status:)
      end

      # stdout of status_expr → NvimStatus. file is worktree-relative when it
      # lives under /app; an empty buffer name means no file.
      def self.parse(stdout)
        data = JSON.parse(Wt::Nvim.unwrap(stdout))
        raise Error, "nvim status: expected an object, got #{stdout.strip[0, 60].inspect}" unless data.is_a?(Hash)

        file = data["file"].to_s
        file = file.empty? ? nil : Wt::Nvim.display_path(file)
        NvimStatus.new(
          running: true,
          ui_count: Integer(data.fetch("uis")),
          buffers: Integer(data.fetch("buffers")),
          modified: Integer(data.fetch("modified")),
          file:,
          line: file && data["line"].to_i.positive? ? data["line"].to_i : nil
        )
      rescue JSON::ParserError, KeyError, TypeError, ArgumentError => e
        raise Error, "nvim status: #{e.message}"
      end
    end
  end
end
