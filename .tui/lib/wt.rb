# frozen_string_literal: true

require "rooibos"
require "json"
require "time"

# wt — terminal dashboard for rails-dev-podman worktrees (docs/design/SPEC.md).
module Wt
  LIB = File.join(__dir__, "wt")

  # Load order: plain values first, then everything that refers to them.
  # Files within a layer must not depend on each other's load order.
  LAYERS = %w[
    config.rb tier.rb theme.rb shell.rb model/*.rb messages.rb messages/*.rb
    commands/*.rb sources/*.rb acp/*.rb nvim/*.rb refresh.rb keymap.rb keys.rb terminal.rb
    actions/*.rb views/widgets.rb views/*.rb update.rb app.rb
  ].freeze

  def self.load!
    LAYERS.flat_map { Dir[File.join(LIB, it)].sort }.uniq.each { require it }
  end
end

Wt.load!
