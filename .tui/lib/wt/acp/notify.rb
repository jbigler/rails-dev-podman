# frozen_string_literal: true

module Wt
  module Acp
    # Desktop notification via notify-send. Fire and forget: no toast either way,
    # and a missing notify-send (or no notification daemon) is silently ignored.
    class Notify < Data.define(:argv, :timeout)
      include Rooibos::Command::Custom

      def call(_out, _token)
        Shell.capture(argv, timeout:, stdin: "")
        nil
      end

      # model → [model, Notify] while the terminal is not focused, else model.
      def self.desktop(model, title, body)
        return model if model.ui.focused

        argv = Ractor.make_shareable(["notify-send", "-a", "wt", "wt: #{title}", body.to_s])
        [model, new(argv:, timeout: model.config.timeout)]
      end
    end
  end
end
