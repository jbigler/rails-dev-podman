# frozen_string_literal: true

require "shellwords"

module Dashboard
  # The task palette: every mise task, listed from the workspace root and run
  # in the selected worktree, in the action panel or (for one that needs a
  # terminal) through newterm.sh.
  module Palette
    class BadArgs < Error; end

    TTL = 60
    # Tasks that prompt, attach, follow or open a shell: they need a terminal.
    TERMINAL = %w[claude claude:newterm claude:notoken claude:notoken:newterm claude:template:promote claude:template:apply
                  console nvim rails exec logs proxy:logs test:rails_watcher test:javascript_watcher
                  down destroy clean allow-ports].freeze

    @cache = {}
    @lock = Mutex.new

    # The root's tasks, cached TTL seconds. Listed at ws.root, never a worktree:
    # a worktree's mise.local.toml is container-writable and loading it may
    # evaluate exec() templates; every task is defined in the root config.
    def self.tasks(ws)
      @lock.synchronize do
        at, tasks = @cache[ws.root]
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless at && now - at < TTL
          tasks = Sources::Tasks.fetch(ws.root)
          @cache[ws.root] = [now, tasks]
        end
        tasks
      end
    end

    def self.reset = @lock.synchronize { @cache.clear }

    def self.mode(name) = TERMINAL.include?(name) ? :terminal : :stream

    def self.argv(task, input)
      words = Shellwords.split(input.to_s)
      raise BadArgs, "#{task.name}: arguments required" if words.empty? && Sources::Tasks.args(task.usage) == :required

      ["mise", "run", task.name, *words]
    rescue ArgumentError => e
      raise BadArgs, "#{task.name}: #{e.message}"
    end

    # The ad-hoc action running argv for the task named name.
    def self.spec(name, argv)
      commands = [argv.freeze].freeze
      Actions::Spec.new(id: "palette:#{name}", label: name, mode: mode(name), scope: :worktree, target: :worktree,
                        argv: ->(*) { commands }, env: {}, confirm: nil, prompt: nil, github: true, base_ok: true)
    end
  end
end
