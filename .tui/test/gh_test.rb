# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# Fixtures in fixtures/gh/ are live captures from this workspace's repo (gh 2.102,
# github/gh-stack 0.2.1): `gh pr view <branch> --json number,title,state,isDraft,
# reviewDecision,statusCheckRollup`, `gh stack view --json`, and their stderr.
# pr_view_pending_mixed.json / pr_view_status_error.json keep real CheckRun
# entries and add an in-progress run and StatusContext entries in the shape gh
# exports them (__typename, context, state, targetUrl, startedAt) — this repo's
# CI posts no commit statuses to capture.
class GhTest < Minitest::Test
  include WtTestHelpers

  Result = Wt::Shell::Result

  class Out
    attr_reader :messages

    def initialize = @messages = []
    def put(message) = @messages << message
  end

  def ok(stdout) = Result.new(stdout:, stderr: "", status: 0, timed_out: false)
  def failed(stderr, status) = Result.new(stdout: "", stderr:, status:, timed_out: false)
  def pr_fixture(name) = Wt::Sources::Pr.parse(fixture("gh", name))

  # --- PR + CI -------------------------------------------------------------

  def test_superseded_and_cancelled_runs_count_once_by_latest_start
    pr = pr_fixture("pr_view_superseded_runs.json")
    # 39 rollup entries: 19 checks ran twice, the first run cancelled by a newer push.
    assert_equal [10_410, "OPEN", false, :review_required], [pr.number, pr.state, pr.draft, pr.review]
    assert_equal [:pass, 20, 0, 20, []], [pr.ci, pr.ci_passed, pr.ci_failed, pr.ci_total, pr.failing]
  end

  def test_failed_check_names_and_skipped_counted_as_passed
    pr = pr_fixture("pr_view_failing.json")
    assert_equal [:fail, 19, 1, 20, ["check-boxes"]], [pr.ci, pr.ci_passed, pr.ci_failed, pr.ci_total, pr.failing]
  end

  def test_pending_run_and_status_context_with_neutral_counted_as_passed
    pr = pr_fixture("pr_view_pending_mixed.json")
    assert_equal [:pending, 5, 0, 7, []], [pr.ci, pr.ci_passed, pr.ci_failed, pr.ci_total, pr.failing]
    assert pr.draft
    assert_nil pr.review, "an empty reviewDecision is no decision"
  end

  def test_status_context_error_fails_even_while_runs_are_pending
    pr = pr_fixture("pr_view_status_error.json")
    assert_equal [:fail, 2, 1, 4, ["ci/circleci: build"]], [pr.ci, pr.ci_passed, pr.ci_failed, pr.ci_total, pr.failing]
  end

  def test_closed_pr_keeps_state_and_no_checks_is_none
    assert_equal "CLOSED", pr_fixture("pr_view_closed.json").state
    pr = Wt::Sources::Pr.parse('{"number":7,"title":"x","state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","statusCheckRollup":[]}')
    assert_equal [:none, 0, :approved], [pr.ci, pr.ci_total, pr.review]
  end

  def test_fetch_runs_in_the_worktree_and_maps_no_pr_to_none
    seen = nil
    capture = lambda do |argv, chdir:, **|
      seen = [argv, chdir]
      failed(fixture("gh", "pr_none.stderr"), 1)
    end
    msg = Wt::Shell.stub(:capture, capture) { Wt::Sources::Pr.fetch(config, "general-work", "general_work") }
    assert_equal :none, msg.pr
    assert_equal "general-work", msg.slug
    assert_equal [%w[gh pr view general_work --json] + [Wt::Sources::Pr::FIELDS], "/ws/general-work"], seen
  end

  def test_fetch_raises_on_auth_failure_so_the_cell_shows_unknown
    Wt::Shell.stub(:capture, failed(fixture("gh", "pr_auth.stderr"), 4)) do
      err = assert_raises(Wt::Error) { Wt::Sources::Pr.fetch(config, "tasks", "feature/tasks") }
      assert_match(/GH_TOKEN/, err.message)
    end
  end

  # --- stack ---------------------------------------------------------------

  def test_stack_entries_trunk_up_with_head_position_and_restack
    stack = Wt::Sources::Stack.parse(fixture("gh", "stack_view_top.json"))
    assert_equal "master", stack.trunk
    assert_equal %w[refactor/stim_sheet_cell_components refactor/stim_sheet_trigger_cell
                    claude/issue-9780-stim-cell-component improvement/stim_sheet_note_cell_components], stack.entries.map(&:branch)
    assert_equal [10_412, 10_413, 9782, 10_410], stack.entries.map(&:number)
    assert_equal [4, 4], [stack.position, stack.size]
    assert stack.needs_restack, "the bottom branch is not on trunk's tip"

    bottom = Wt::Sources::Stack.parse(fixture("gh", "stack_view_bottom.json"))
    assert_equal [1, 2], [bottom.position, bottom.size]
  end

  def test_merged_branches_leave_the_stack_and_do_not_ask_for_restack
    data = JSON.parse(fixture("gh", "stack_view_top.json"))
    data["branches"][0].merge!("isMerged" => true, "pr" => { "number" => 10_412, "state" => "MERGED" })
    stack = Wt::Sources::Stack.parse(JSON.generate(data))
    assert_equal [3, 3], [stack.position, stack.size]
    refute stack.needs_restack, "only the merged branch needed a rebase"
  end

  def test_not_in_a_stack_and_trunk_are_empty_other_failures_raise
    { "stack_not_in_stack.stderr" => 2, "stack_trunk.stderr" => 6 }.each do |file, status|
      msg = Wt::Shell.stub(:capture, failed(fixture("gh", file), status)) { Wt::Sources::Stack.fetch(config, "general-work") }
      assert_empty msg.stack.entries, file
      assert_nil msg.stack.position
    end
    Wt::Shell.stub(:capture, failed(fixture("gh", "pr_auth.stderr"), 4)) do
      assert_raises(Wt::Error) { Wt::Sources::Stack.fetch(config, "general-work") }
    end
  end

  def test_fetch_fills_review_and_ci_per_entry_and_tolerates_one_failure
    prs = { "10412" => "pr_view_failing.json", "10413" => "pr_view_superseded_runs.json", "10410" => "pr_view_pending_mixed.json" }
    capture = lambda do |argv, chdir:, **|
      raise "ran outside the worktree" unless chdir == "/ws/stim"
      next ok(fixture("gh", "stack_view_top.json")) if argv == Wt::Sources::Stack::VIEW

      file = prs[argv[3]]
      file ? ok(fixture("gh", file)) : failed("HTTP 502", 1)
    end
    stack = Wt::Shell.stub(:capture, capture) { Wt::Sources::Stack.fetch(config, "stim") }.stack
    assert_equal [:fail, :pass, :none, :pending], stack.entries.map(&:ci)
    assert_equal [:review_required, :review_required, nil, nil], stack.entries.map(&:review)
    assert_equal [false, false, false, true], stack.entries.map(&:draft)
    assert_equal 4, stack.position
  end

  # --- actions -------------------------------------------------------------

  def tasks_model = model.then { it.with(ui: it.ui.with(selected: "tasks")) }

  def test_stack_keys_target_the_selected_worktree
    { "[" => %w[gh stack down], "]" => %w[gh stack up], "R" => %w[gh stack rebase], "P" => %w[gh stack push] }.each do |key, argv|
      _, cmd = step(tasks_model, key)
      assert_kind_of Wt::Commands::StackOp, cmd
      assert_equal [argv, "tasks"], [cmd.argv, cmd.worktree.slug], key
      assert Ractor.shareable?(cmd), key
    end
  end

  def test_open_pr_without_a_pr_toasts_instead_of_running_gh
    m, cmd = step(tasks_model.put(:prs, "tasks", :none), "p")
    assert_kind_of Wt::Commands::ExpireToast, cmd
    assert_match(/no PR for feature\/tasks/, m.ui.toasts.last.text)

    _, cmd = step(tasks_model.put(:prs, "tasks", Wt::PrStatus.new(number: 3)), "p")
    assert_equal [%w[gh pr view --web], "/ws/tasks"], [cmd.argv, cmd.cwd]
  end

  def test_stack_op_refuses_when_nvim_write_fails
    op = Wt::Commands::StackOp.new(config: config, worktree: worktree("tasks"), label: "restack", argv: %w[gh stack rebase])
    out = Out.new
    refused = failed("nvim: :wa left 1 unsaved buffer: app/models/task.rb", 1)
    Wt::Nvim.stub(:write_all, refused) do
      Wt::Shell.stub(:capture, ->(*) { flunk "ran the stack command after a failed :wa" }) { op.call(out, nil) }
    end
    msg, *rest = out.messages
    assert_empty rest
    refute_equal 0, msg.status
    refute msg.refresh
    m, = step(model, msg)
    assert_equal "restack: nvim :wa failed: nvim: :wa left 1 unsaved buffer: app/models/task.rb", m.ui.toasts.last.text
    assert_equal :error, m.ui.toasts.last.level
  end

  def test_stack_op_runs_in_the_worktree_after_a_successful_write
    op = Wt::Commands::StackOp.new(config: config, worktree: worktree("tasks"), label: "stack up", argv: %w[gh stack up])
    out = Out.new
    seen = nil
    capture = lambda do |argv, chdir:, timeout:, **|
      seen = [argv, chdir, timeout]
      ok("")
    end
    Wt::Nvim.stub(:write_all, ok("")) { Wt::Shell.stub(:capture, capture) { op.call(out, nil) } }
    assert_equal [%w[gh stack up], "/ws/tasks", 60.0], seen
    msg, *rest = out.messages
    assert_empty rest
    assert_equal [0, true], [msg.status, msg.refresh]
    assert Ractor.shareable?(msg)
  end
end
