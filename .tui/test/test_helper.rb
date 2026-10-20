# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "minitest/autorun"
require "rooibos"
require "rooibos/test_helper"
require_relative "../lib/wt"

module WtTestHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)

  def fixture(*path) = File.read(File.join(FIXTURES, *path))
  def fixture_path(*path) = File.join(FIXTURES, *path)

  # A Config pointing at a throwaway root; no environment involved.
  def config(root: "/ws", prefix: "filial", base_name: "master")
    Wt::Config.new(root:, prefix:, base_name:, theme: :light, accent: :orange, timeout: 5.0, action_timeout: 60.0)
  end

  def worktree(slug, id: 1, branch: "feature/#{slug}", base: false)
    Wt::Worktree.new(slug:, path: "/ws/#{slug}", branch:, head: "abc1234", id:, base:)
  end

  def model(worktrees: [worktree("master", id: 0, branch: "main", base: true), worktree("tasks")], **ui)
    Wt::Model.new(config: config, worktrees:, ui: Wt::Ui.new(selected: worktrees.first&.slug, **ui), now: Time.at(1_800_000_000))
  end

  # Fold one or more messages / key events through Update, returning [model, last command].
  def step(model, *msgs)
    cmd = nil
    msgs.each do |m|
      m = key(m) if m.is_a?(String)
      model, cmd = Rooibos.normalize_init(Wt::Update.call(m, model))
    end
    [model, cmd]
  end

  # "s", "S", "ctrl+b", "enter", "f1" → RatatuiRuby key event
  def key(name)
    *mods, code = name.split("+")
    code = "+" if name.end_with?("++")
    RatatuiRuby::Event::Key.new(code:, modifiers: mods)
  end

  # Render the model's view into a test terminal and return the screen text.
  def render(model, width: model.ui.width, height: model.ui.height)
    out = nil
    with_test_terminal(width, height) do
      widget = Wt::Views::Root.call(model, RatatuiRuby::TUI.new)
      RatatuiRuby.draw { |f| f.render_widget(widget, f.area) }
      out = buffer_content.join("\n")
    end
    out
  end
end

class Minitest::Test
  include Rooibos::TestHelper
  include WtTestHelpers
end
