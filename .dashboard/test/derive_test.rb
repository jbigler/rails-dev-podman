# frozen_string_literal: true

require_relative "test_helper"

# §5.2 service mapping, §5.3 checks, §7.2 agent derivation, and Raw → [Worktree].
class DeriveTest < Minitest::Test
  C = Dashboard::Container

  def ctr(state: "running", health: nil, exit_code: 0, started_at: Time.at(1000))
    C.new(name: "c", state:, health:, exit_code:, started_at:)
  end

  def worktrees(raw: fixture_raw, failed: {}) = Dashboard::Derive.worktrees(ws, raw, failed)
  def worktree(name, **) = worktrees(**).find { it.name == name }

  def test_service_state_mapping
    up = { "ActiveState" => "active" }
    {
      [{ "ActiveState" => "failed" }, ctr] => :failed,
      [up, ctr(state: "exited", exit_code: 1)] => :failed,
      [up, ctr(health: "unhealthy")] => :failed,
      [{ "ActiveState" => "activating" }, nil] => :starting,
      [up, ctr(health: "starting")] => :starting,
      [up, ctr(health: "healthy")] => :up,
      [up, ctr] => :up,
      [{ "ActiveState" => "inactive" }, ctr(state: "exited", exit_code: 0)] => :stopped,
      [nil, nil] => :stopped
    }.each { |(unit, c), want| assert_equal want, Dashboard::Services.state(unit, c), [unit, c].inspect }
  end

  def test_svc_summary
    s = ->(*states) { states.map { Dashboard::Service.new(label: "x", unit: "u", state: it, port: nil, health: nil) } }
    assert_equal :failed, Dashboard::Services.summary(s.(:up, :failed, :starting))
    assert_equal :starting, Dashboard::Services.summary(s.(:up, :starting))
    assert_equal :up, Dashboard::Services.summary(s.(:up, :stopped))
    assert_equal :stopped, Dashboard::Services.summary(s.(:stopped))
    assert_equal :unknown, Dashboard::Services.summary(Dashboard::UNKNOWN)
  end

  def test_six_services_with_nvim
    services = Dashboard::Services.for(ws, "wt-stacked", {}, {}, {})
    assert_equal %w[rails postgres redis rustfs playwright nvim], services.map(&:label)
    assert_equal "myproj-nvim@wt-stacked.service", services.last.unit
  end

  def run_(name, conclusion, started, status: "COMPLETED", workflow: "ci")
    { "__typename" => "CheckRun", "name" => name, "workflowName" => workflow, "status" => status, "conclusion" => conclusion,
      "startedAt" => started }
  end

  def test_checks_keep_only_the_latest_run
    rollup = [run_("tests", "CANCELLED", "2026-01-01T10:00:00Z"), run_("tests", "SUCCESS", "2026-01-01T11:00:00Z"),
              run_("deploy", "SKIPPED", "2026-01-01T11:00:00Z")]
    assert_equal({ pass: 1, fail: 0, pending: 0 }, Dashboard::Sources::Checks.summarize(rollup))
  end

  def test_checks_latest_cancelled_failed_pending_and_contexts
    rollup = [run_("a", "CANCELLED", "2026-01-01T11:00:00Z"), run_("b", "TIMED_OUT", "2026-01-01T11:00:00Z"),
              run_("c", nil, "2026-01-01T11:00:00Z", status: "IN_PROGRESS"), run_("d", "SUCCESS", "2026-01-01T11:00:00Z"),
              { "__typename" => "StatusContext", "context" => "ci/x", "state" => "PENDING" },
              { "__typename" => "StatusContext", "context" => "ci/y", "state" => "ERROR" }]
    assert_equal({ pass: 1, fail: 3, pending: 2 }, Dashboard::Sources::Checks.summarize(rollup))
    assert_nil Dashboard::Sources::Checks.summarize([run_("x", "NEUTRAL", "t")])
  end

  def file(v: 2, phase: nil, state: nil, ts: Time.at(2000), **rest)
    Dashboard::StatusFile.new(v:, phase:, state:, ts:, message: rest[:message], tool: rest[:tool], last_message: rest[:last_message],
                              rtk: nil)
  end

  def test_agent_derivation_table
    rows = [
      [nil, file(phase: "working"), :off],                        # no container: the file may be stale
      [ctr(state: "exited"), file(phase: "working"), :off],
      [ctr, nil, :working],                                       # running, no file yet
      [ctr(started_at: Time.at(3000)), file(phase: "done"), :idle], # file older than the container
      [ctr, file(phase: "permission"), :permission],
      [ctr, file(phase: "question"), :question],
      [ctr, file(phase: "working"), :working],
      [ctr, file(phase: "done"), :your_turn],                     # a finished turn without a last message
      [ctr, file(phase: "idle"), :idle],
      [ctr, file(phase: "offline"), :off],
      [ctr, file(v: 0, state: "working"), :working],              # v1 files
      [ctr, file(v: 0, state: "waiting"), :your_turn],
      [ctr, file(v: 0, state: "offline"), :off]
    ]
    rows.each_with_index do |(c, f, want), i|
      assert_equal want, Dashboard::AgentStatus.derive(c, f).state, "row #{i}"
    end
    assert_equal Dashboard::UNKNOWN, Dashboard::AgentStatus.derive(Dashboard::UNKNOWN, nil)
  end

  # A finished turn whose last message asks something waits for a reply; any other is just the user's turn.
  def test_a_done_turn_ending_in_a_question_waits_for_a_reply
    {
      "Go with B, or change the canvas first?" => :reply,
      "Which one do you **prefer?**" => :reply,
      "(shall I go on?)" => :reply,
      "He said “ready?”" => :reply,
      "Ready? \n\t " => :reply,
      "It's ‘done?’ `x?`_*\"']" => :reply,
      "Done. Tests pass." => :your_turn,
      "Is it? It is." => :your_turn,
      "" => :your_turn
    }.each do |last_message, want|
      assert_equal want, Dashboard::AgentStatus.derive(ctr, file(phase: "done", last_message:)).state, last_message.inspect
    end
    assert_equal :your_turn, Dashboard::AgentStatus.derive(ctr, file(phase: "done")).state
    assert_equal :your_turn, Dashboard::AgentStatus.derive(ctr, file(v: 0, state: "waiting", last_message: "ok?")).state
  end

  def test_v2_details_and_v1_has_no_last_message
    a = Dashboard::AgentStatus.derive(ctr, file(phase: "done", last_message: "… end", tool: "Bash: ls"))
    assert_equal ["… end", "Bash: ls", Time.at(2000)], [a.last_message, a.tool, a.since]
    assert_nil Dashboard::AgentStatus.derive(ctr, file(v: 0, state: "waiting", last_message: "x")).last_message
  end

  def test_ages
    now = Time.at(100_000)
    assert_equal %w[12s 4m 2h 3d], [12, 240, 7200, 3 * 86_400].map { Dashboard::AgentStatus.age(now - it, now) }
  end

  def test_stopped_worktrees_listed
    list = worktrees
    assert_equal 16, list.size
    assert_equal "master", list.last.name
    assert_equal list[0...-1].map(&:name).sort, list[0...-1].map(&:name)
    assert_equal [:stopped] * 6, list.find { it.name == "wt-02" }.services.map(&:state)
  end

  def test_derive_marks_failures
    failed = { "units" => "systemctl: no user session", "prs" => "gh: not logged in" }
    wt = worktree("wt-01", failed:)
    assert_equal Dashboard::UNKNOWN, wt.services
    assert_equal Dashboard::UNKNOWN, wt.pr
    refute_equal Dashboard::UNKNOWN, wt.agent # containers still readable
  end

  def test_open_pr_with_checks_and_local_commit_count
    wt = worktree("wt-stacked")
    assert_equal [10_329, 6, { pass: 17, fail: 0, pending: 0 }], [wt.pr.number, wt.pr.commits, wt.pr.checks]
    assert_equal :off, wt.agent.state # only an -agent container runs there, never a -claude one
  end

  def test_pr_falls_back_to_the_index
    branch, merged = fixture_raw.pr_index.find { |_, pr| pr.state == :merged }
    ref = Dashboard::WorktreeRef.new(name: "done", path: "#{ROOT}/done", branch:, head_sha: "abc", base: false)
    raw = fixture_raw.with(refs: [ref])
    assert_equal merged, worktrees(raw:).first.pr
  end

  def test_ports_from_the_unit_env
    services = worktree("wt-stacked").services
    assert_equal [:up] * 6, services.map(&:state)
    assert_equal %w[13022 55454 17022], services.values_at(0, 1, 5).map(&:port)
    assert_nil services[3].port # S3_PORT not in the file
    assert_nil worktree("master").services.first.port # no .unit-env file yet
  end
end
