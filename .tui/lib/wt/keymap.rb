# frozen_string_literal: true

module Wt
  # The one key table. Keys.handle looks bindings up here, the bottom bar shows the
  # `hint:` ones, and the `?` overlay lists all of them — so help cannot drift
  # from the bindings.
  #
  # keys:    normalized key names (see Keys.normalize): "s", "S", "ctrl+b", "f1", "enter", "up"
  # action:  Actions.<action>(model, *args) → Model | [Model, command]
  # screens: where it applies; :all or an Array of :worktrees / :agents / :chat
  # hint:    shown in the bottom bar of those screens
  module Keymap
    class Binding < Data.define(:keys, :action, :args, :label, :group, :screens, :hint)
      def initialize(keys:, action:, label:, group:, args: [], screens: :all, hint: false)
        super
      end

      def on?(screen) = screens == :all || screens.include?(screen)
      def key_label = KEY_LABELS.fetch(keys.join(" "), keys.join(" "))
    end

    # How a key group is printed in the bottom bar and help ("↑↓", "[ ]", "1-3").
    KEY_LABELS = {
      "up down k j" => "↑↓", "enter" => "⏎", "esc" => "Esc", "f1" => "F1", "f2" => "F2", "f3" => "F3", "tab" => "Tab",
      "[" => "[", "]" => "]", "1 2 3" => "1-3", "ctrl+]" => "^]", "ctrl+b" => "^b", "ctrl+o" => "^o",
      "ctrl+1 ctrl+2 ctrl+3 ctrl+4 ctrl+5 ctrl+6 ctrl+7 ctrl+8 ctrl+9" => "^1-^9", "{ }" => "{ }", "q ctrl+c" => "q",
      "o ctrl+o" => "o"
    }.freeze

    B = Binding
    W = %i[worktrees].freeze
    WA = %i[worktrees agents].freeze
    C = %i[chat].freeze
    WC = %i[worktrees chat].freeze

    BINDINGS = [
      # screens
      B.new(keys: %w[f1], action: :show_screen, args: [:worktrees], label: "worktrees", group: "Screens"),
      B.new(keys: %w[f2], action: :show_screen, args: [:agents], label: "agents", group: "Screens"),
      B.new(keys: %w[f3], action: :show_screen, args: [:chat], label: "chat", group: "Screens"),
      B.new(keys: %w[tab], action: :next_screen, label: "next screen", group: "Screens"),
      # selection
      B.new(keys: %w[up down k j], action: :move, label: "select", group: "Navigate", hint: true),
      B.new(keys: %w[enter], action: :open, label: "open", group: "Navigate", hint: true),
      B.new(keys: %w[esc], action: :back, label: "back", group: "Navigate"),
      B.new(keys: %w[/], action: :start_filter, label: "filter", group: "Navigate", screens: W),
      B.new(keys: %w[v], action: :toggle_agents_view, label: "cards / list", group: "Navigate", screens: %i[agents], hint: true),
      B.new(keys: %w[ctrl+1 ctrl+2 ctrl+3 ctrl+4 ctrl+5 ctrl+6 ctrl+7 ctrl+8 ctrl+9], action: :jump_agent, label: "agent by urgency", group: "Navigate", screens: %i[agents]),
      B.new(keys: ["{", "}"], action: :move_tool_call, label: "prev / next tool call", group: "Navigate", screens: WC),
      # agent
      B.new(keys: %w[a], action: :chat, label: "chat", group: "Agent", hint: true, screens: WA),
      B.new(keys: %w[A], action: :new_session, label: "new session", group: "Agent"),
      B.new(keys: %w[i], action: :focus_input, label: "reply", group: "Agent", screens: WC),
      B.new(keys: %w[1 2 3], action: :answer_permission, label: "answer", group: "Agent", hint: true),
      B.new(keys: %w[K], action: :stop_agent, label: "stop agent", group: "Agent"),
      B.new(keys: ["ctrl+]"], action: :leave_chat, label: "leave chat", group: "Agent", screens: C, hint: true),
      B.new(keys: %w[ctrl+b], action: :toggle_sidebar, label: "context", group: "Agent", screens: C, hint: true),
      # nvim
      B.new(keys: %w[n], action: :nvim_here, label: "nvim here", group: "nvim", hint: true),
      B.new(keys: %w[N], action: :nvim_window, label: "nvim window", group: "nvim", hint: true),
      B.new(keys: %w[o ctrl+o], action: :open_tool_call, label: "open in nvim", group: "nvim", hint: true, screens: WC),
      B.new(keys: %w[d], action: :show_diff, label: "diff", group: "nvim", screens: C, hint: true),
      # pod
      B.new(keys: %w[s], action: :toggle_pod, label: "pod up/down", group: "Pod", hint: true, screens: WA),
      B.new(keys: %w[r], action: :restart_service, label: "restart service", group: "Pod", screens: WA),
      B.new(keys: %w[L], action: :logs, label: "logs", group: "Pod", hint: true, screens: WA),
      # stack
      B.new(keys: ["["], action: :stack_down, label: "stack down", group: "Stack", screens: W),
      B.new(keys: ["]"], action: :stack_up, label: "stack up", group: "Stack", screens: W),
      B.new(keys: %w[R], action: :restack, label: "restack", group: "Stack", screens: W),
      B.new(keys: %w[P], action: :push_stack, label: "push stack", group: "Stack", screens: W),
      B.new(keys: %w[p], action: :open_pr, label: "open PR", group: "Stack", screens: W),
      # worktrees
      B.new(keys: %w[c], action: :new_worktree, label: "new worktree", group: "Worktrees", hint: true, screens: W),
      B.new(keys: %w[d], action: :remove_worktree, label: "remove worktree", group: "Worktrees", screens: W),
      # app
      B.new(keys: %w[T], action: :toggle_theme, label: "theme", group: "App", hint: true),
      B.new(keys: %w[?], action: :toggle_help, label: "more", group: "App", hint: true),
      B.new(keys: %w[q ctrl+c], action: :quit, label: "quit", group: "App", hint: true)
    ].freeze

    def self.lookup(key, screen) = BINDINGS.find { it.on?(screen) && it.keys.include?(key) }
    def self.hints(screen) = BINDINGS.select { it.hint && it.on?(screen) }
    def self.groups = BINDINGS.group_by(&:group)
  end
end
