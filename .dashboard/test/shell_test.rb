# frozen_string_literal: true

require "test_helper"

class ShellTest < Minitest::Test
  def test_missing_binary_is_status_127
    result = Dashboard::Shell::Real.new.run(["no-such-binary-xyz"])

    assert_equal 127, result.status
    assert_predicate result, :broken?
  end

  def test_timeout_kills_the_group
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = Dashboard::Shell::Real.new.run(["sh", "-c", "sleep 5 & sleep 5"], timeout: 0.3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert result.timed_out
    assert_operator elapsed, :<, 2
  end
end
