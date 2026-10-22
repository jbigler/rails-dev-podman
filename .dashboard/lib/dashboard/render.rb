# frozen_string_literal: true

require "erb"
require "erubi"
require "tilt"
require "tilt/erubi"

module Dashboard
  # The page and the fragments the server pushes (a list row, the detail pane,
  # the header), from the views/ templates. Compiled once at load; output is
  # HTML-escaped unless a template says <%== %>.
  module Render
    VIEWS = File.expand_path("../../views", __dir__)
    TEMPLATES = %w[layout page _header _row _detail].to_h do |name|
      [name, Tilt::ErubiTemplate.new(File.join(VIEWS, "#{name}.erb"), escape_html: true, freeze: true)]
    end.freeze

    # An HTML id from a worktree name: anything outside [A-Za-z0-9_-] becomes _<hex>.
    def self.dom_id(prefix, name) = "#{prefix}-" + name.gsub(/[^A-Za-z0-9_-]/) { format("_%02x", it.ord) }

    # The page's URL for a worktree.
    def self.path(name) = "/w/#{ERB::Util.url_encode(name)}"

    def self.row(wt, selected:) = view("_row", wt:, selected:)
    def self.detail(wt, state) = view("_detail", wt:, state:)

    # repo: the owner/name the header and the title show.
    def self.header(state, repo:) = view("_header", state:, repo:)

    # The list, the detail pane of the worktree named `selected` (nil: none) and the action panel.
    def self.page(state, selected, repo:) = view("page", state:, repo:, selected: state.worktrees.find { it.name == selected })

    # The HTML document around the block's output: token meta tag, import map, title.
    def self.layout(state, token:, repo:, &) = TEMPLATES.fetch("layout").render(View::INSTANCE, state:, token:, repo:, &)

    def self.view(name, **locals) = TEMPLATES.fetch(name).render(View::INSTANCE, locals)
    private_class_method :view
  end
end
