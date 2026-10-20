# frozen_string_literal: true

module Wt
  # The Rooibos root fragment: Rooibos.run(Wt::App).
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
  end
end
