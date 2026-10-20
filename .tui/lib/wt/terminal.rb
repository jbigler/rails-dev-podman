# frozen_string_literal: true

module Wt
  # Hands the terminal to an interactive program (nvim attach, `mise run claude`)
  # and takes it back. Called from Update on the main thread, so the render loop
  # is paused for exactly as long as the program runs; the next frame redraws
  # everything on a fresh alternate screen.
  module Terminal
    # Returns the program's exit status (nil when it could not start).
    def self.handover(argv, chdir:, env: {})
      RatatuiRuby.restore_terminal
      system(env, *argv, chdir:)
      $?&.exitstatus
    ensure
      RatatuiRuby.init_terminal
    end
  end
end
