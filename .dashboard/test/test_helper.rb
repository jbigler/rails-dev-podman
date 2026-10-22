# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
require "bundler/setup"
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../lib/dashboard"

# Replays canned results for argv prefixes and records every call, so no test
# needs podman, systemd, gh or mise.
class FakeShell
  Call = Data.define(:argv, :chdir, :env)
  attr_reader :calls

  # responses: "argv joined by spaces" prefix => Shell::Result
  def initialize(responses = {})
    @responses = responses
    @calls = []
  end

  def run(argv, chdir: nil, timeout: nil, env: {})
    @calls << Call.new(argv:, chdir:, env:)
    line = argv.join(" ")
    key = @responses.keys.select { line.start_with?(it) }.max_by(&:length)
    key ? @responses[key] : Dashboard::Shell::Result.fail("#{argv.first}: not stubbed", status: 127)
  end
end

# Each child is looked up by its command after the scope wrapper ("mise run up")
# and yields that script's lines, then exits with its status. A held command
# blocks after its lines until #release or a kill (which makes the status nil).
class FakeSpawner
  SCOPE = %w[systemd-run --user --scope --collect --quiet --].freeze
  Call = Data.define(:argv, :env, :chdir)

  class Child
    def initialize(lines, status, gate)
      @lines = lines
      @status = status
      @gate = gate
      @killed = false
    end

    def each_line(&)
      @lines.each(&)
      @gate&.pop
    end

    def wait = @killed ? nil : @status

    def kill
      @killed = true
      @gate&.push(:killed)
    end
  end

  # script: command => [lines, status]; hold: commands that block.
  def initialize(script = {}, hold: [])
    @script = script
    @hold = hold
    @lock = Mutex.new
    @calls = []
    @gates = Hash.new { |gates, command| gates[command] = Thread::Queue.new }
  end

  def spawn(argv, env:, chdir:)
    command = argv.drop(SCOPE.size).join(" ")
    @lock.synchronize do
      @calls << Call.new(argv:, env:, chdir:)
      lines, status = @script.fetch(command, [[], 0])
      Child.new(lines, status, (@gates[command] if @hold.include?(command)))
    end
  end

  def calls = @lock.synchronize { @calls.dup }
  def commands = calls.map { it.argv.drop(SCOPE.size).join(" ") }
  def release(command) = @lock.synchronize { @gates[command] } << :go
end

module DashboardTestHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)
  ROOT = "/home/dev/workspace/myproj"
  NOW = Time.utc(2026, 10, 20, 14, 3, 0)

  def fixture(*path) = File.read(File.join(FIXTURES, *path))

  def ws = Dashboard::Workspace.new(root: ROOT, prefix: "myproj", base_name: "master")

  # FakeShell responses for GitSafety's filter-driver read in each path:
  # exit 1, no output — the repo configures no filters.
  def no_filters(*paths)
    paths.to_h { ["git -C #{it} config --name-only", Dashboard::Shell::Result.new(stdout: "", stderr: "", status: 1, timed_out: false)] }
  end

  # The fixture machine: 16 worktrees, wt-stacked on a 21-branch stack, pods
  # up for master, wt-01, wt-06, wt-09 and wt-stacked; only wt-stacked has a
  # .unit-env file.
  def fixture_raw
    s = Dashboard::Sources
    refs = s::Worktrees.parse(fixture("git-worktree-list.txt"), base_path: "#{ROOT}/master")
    units = s::Units.parse(fixture("systemctl.master.txt")).merge(s::Units.parse(fixture("systemctl.wt-stacked.txt")))
    Dashboard::Raw.empty.with(
      refs:,
      git: { "master" => s::GitStatus.parse(fixture("git-status.master.txt")),
             "wt-stacked" => s::GitStatus.parse(fixture("git-status.wt-stacked.txt")) },
      env: { "wt-stacked" => [NOW, s::UnitEnv.parse(fixture("unit-env.wt-stacked.env"))] },
      units:,
      containers: s::Containers.parse(fixture("podman-ps.json")),
      prs: s::OpenPrs.parse(fixture("gh-pr-list-open.json")),
      pr_index: s::PrIndex.parse(fixture("gh-pr-list.json")),
      commits: { "wt-stacked" => 6 },
      stacks: { "wt-stacked" => s::Stack.parse(fixture("gh-stack-view.wt-stacked.json")) },
      stale_units: [],
      autostart: :disabled
    )
  end

  def with_shell(shell)
    previous = Dashboard::Shell.backend
    Dashboard::Shell.backend = shell
    yield shell
  ensure
    Dashboard::Shell.backend = previous
  end
end

class Minitest::Test
  include DashboardTestHelpers
end
