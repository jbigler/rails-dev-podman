# frozen_string_literal: true

module Dashboard
  # The registry of what the page's buttons run (spec "Actions"). Every argv is
  # an array, never a shell string.
  module Actions
    # mode: :stream (output to the action panel) or :terminal (newterm.sh).
    # scope: what one running job locks and where it runs — :worktree (that
    # worktree, its folder) or :workspace (every workspace action, ROOT).
    # target: what the button belongs to — :worktree (the detail pane, POST
    # /w/<W>/act/<id>) or :workspace (the header, POST /act/<id>).
    # argv: ->(ws, wt, input) { [[String]] }, run in order up to the first failure.
    # env: Hash, or ->(discard) { Hash } for an action with the "discard uncommitted changes" choice.
    # confirm: the question asked first; prompt: the question whose answer is `input` (required).
    # github: the job's end hints the GitHub poller; base_ok: false keeps it off the base worktree.
    Spec = Data.define(:id, :label, :mode, :scope, :target, :argv, :env, :confirm, :prompt, :github, :base_ok) do
      def environment(discard) = discardable? ? env.(discard) : env
      def discardable? = env.respond_to?(:call)
    end

    SERVICES = %w[rails db redis rustfs playwright nvim].freeze
    FORCE = { "FORCE" => "1" }.freeze

    def self.mise(*args) = ["mise", "run", *args]

    def self.spec(id, label, argv, mode: :stream, scope: :worktree, target: scope, env: {}, confirm: nil, prompt: nil, github: false, base_ok: true)
      Spec.new(id:, label:, mode:, scope:, target:, argv:, env:, confirm:, prompt:, github:, base_ok:)
    end

    # A spec running one fixed command.
    def self.fixed(id, label, *argv, **)
      commands = [argv.freeze].freeze
      spec(id, label, ->(_ws, _wt, _input) { commands }, **)
    end

    # podman attach to the worktree's running Claude container, else start one.
    def self.claude(ws, wt, _input)
      name = ws.container(wt.name, "claude")
      r = Shell.run(["podman", "container", "inspect", "--format", "{{.State.Running}}", name])
      r.ok? && r.stdout.strip == "true" ? [["podman", "attach", name]] : [mise("claude")]
    end

    WORKSPACE = { scope: :workspace }.freeze

    ALL = [
      fixed("up", "up", *mise("up")),
      fixed("stop", "stop", *mise("stop")),
      fixed("down", "down", *mise("down"), env: FORCE, confirm: "Stop this worktree and delete its db, rustfs and node_modules volumes?"),
      *SERVICES.map { fixed("restart-#{it}", "restart #{it}", *mise("restart", it)) },
      spec("restart-all", "restart all", ->(_ws, _wt, _input) { [mise("stop"), mise("up")] }),
      fixed("test", "test", *mise("test")),
      fixed("test-rails", "test rails", *mise("test:rails")),
      fixed("test-javascript", "test javascript", *mise("test:javascript")),
      fixed("test-system", "test system", *mise("test:rails_system")),
      fixed("watch-rails", "watch rails", *mise("test:rails_watcher"), mode: :terminal),
      fixed("watch-javascript", "watch javascript", *mise("test:javascript_watcher"), mode: :terminal),
      fixed("nvim", "nvim", *mise("nvim"), mode: :terminal),
      fixed("console", "console", *mise("console"), mode: :terminal),
      fixed("shell", "shell", *mise("rails"), mode: :terminal),
      spec("claude", "claude", method(:claude), mode: :terminal),
      fixed("share", "share", *mise("wt:share")),
      fixed("unshare", "unshare", *mise("wt:unshare")),
      fixed("stack-push", "stack push", "gh", "stack", "push", github: true),
      fixed("stack-up", "stack up", "gh", "stack", "up", github: true),
      fixed("stack-down", "stack down", "gh", "stack", "down", github: true),
      fixed("restack", "restack", "gh", "stack", "rebase", mode: :terminal),
      spec("wt-rm", "remove worktree", ->(_ws, wt, _input) { [mise("wt:rm", wt.name)] },
           **WORKSPACE, target: :worktree, env: ->(discard) { discard ? FORCE : {} }, confirm: "Remove this worktree?", github: true,
           base_ok: false),
      spec("wt-create", "new worktree", ->(_ws, _wt, input) { [mise("wt", input)] },
           **WORKSPACE, github: true, prompt: "Branch, PR number or new branch name:"),
      fixed("units-install", "install units", *mise("units:install"), **WORKSPACE),
      fixed("autostart-on", "start at login: on", *mise("dashboard:autostart", "on"), **WORKSPACE),
      fixed("autostart-off", "start at login: off", *mise("dashboard:autostart", "off"), **WORKSPACE)
    ].freeze
    BY_ID = ALL.to_h { [it.id, it] }.freeze

    def self.find(id) = BY_ID[id]

    # The specs a worktree's detail pane offers.
    def self.for_worktree(wt) = ALL.select { it.target == :worktree && (it.base_ok || !wt.base) }
    private_class_method :mise, :spec, :fixed, :claude
  end
end
