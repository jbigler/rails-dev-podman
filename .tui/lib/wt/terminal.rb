# frozen_string_literal: true

module Wt
  # Hands the terminal to an interactive program (nvim attach, `mise run logs`)
  # and takes it back. Called from Update on the main thread, so the render loop
  # is paused for exactly as long as the program runs; the next frame redraws
  # everything on a fresh alternate screen.
  module Terminal
    # Returns the program's exit status (nil when it could not start).
    #
    # Out of raw mode, ^C sends SIGINT to the whole foreground process group, wt
    # included, and RatatuiRuby's own INT trap exits — so ^C out of `podman logs -f`
    # would quit wt. A no-op Ruby handler (not "IGNORE", which the child would
    # inherit) keeps wt alive while the child still gets the default action on exec.
    def self.handover(argv, chdir:, env: {})
      previous = Signal.trap("INT") {}
      RatatuiRuby.restore_terminal
      system(env, *argv, chdir:)
      $?&.exitstatus
    ensure
      RatatuiRuby.init_terminal
      Signal.trap("INT", previous || "DEFAULT")
    end
  end
end
