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

module DashboardTestHelpers
  FIXTURES = File.expand_path("fixtures", __dir__)
  ROOT = "/home/dev/workspace/myproj"
  NOW = Time.utc(2026, 10, 20, 14, 3, 0)

  def fixture(*path) = File.read(File.join(FIXTURES, *path))

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
