# frozen_string_literal: true

module Wt
  # The Rooibos root fragment. Start it with App.run, not Rooibos.run directly.
  module App
    module Init
      def self.call = App.init
    end
    Update = Wt::Update
    View = Views::Root

    def self.init(config = Config.discover, cwd: Dir.pwd)
      area = RatatuiRuby.get_viewport_area
      ui = Ui.new(width: area.width, height: area.height, theme: config.theme, accent: config.accent, selected: launch_slug(config, cwd))
      Refresh.start(Model.new(config:, ui:))
    end

    # The worktree wt was started from, so it opens with that row selected.
    def self.launch_slug(config, cwd)
      rel = File.expand_path(cwd).delete_prefix("#{config.root}/")
      rel == File.expand_path(cwd) ? nil : rel.split("/").first
    end

    # fps is the idle redraw rate (poll timeout), not input latency: a key or a
    # background message is handled as soon as it arrives. 60 burns a core on idle.
    FPS = 8

    # Runs until `q`, TERM or HUP, then ends the process. Every way out restores the
    # terminal (RatatuiRuby.run's ensure) and none leaves the process behind:
    # - TERM/HUP unwind to Rooibos' quit point like `q`, so its shutdown cancels the
    #   background commands (followers kill their process groups).
    # - Then exit! rather than exit: a normal exit kills the command threads, whose
    #   Open3 ensure blocks wait for their child (gh, git, podman) to finish — the
    #   process lingered for seconds behind an already restored terminal.
    # - A crash skips Rooibos' shutdown; report it and leave the same way.
    def self.run
      %w[TERM HUP].each { |sig| Signal.trap(sig) { throw Rooibos::Runtime::QUIT } }
      Rooibos.run(self, fps: FPS)
      status = 0
    rescue Exception => e # rubocop:disable Lint/RescueException -- a crash of any kind
      warn e.full_message
      status = 1
    ensure
      $stdout.flush
      $stderr.flush
      exit!(status || 1)
    end
  end
end
