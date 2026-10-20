# frozen_string_literal: true

module Wt
  module Sources
    # PR + CI for one worktree's branch (spec "Data sources"): `gh pr view <branch>
    # --json ...` run inside the worktree, so gh resolves the repo from its remote.
    module Pr
      FIELDS = "number,title,state,isDraft,reviewDecision,statusCheckRollup"

      # No prompts, no colour, and no upgrade notices appended to stderr (which
      # would replace the real error as a toast's last line).
      GH_ENV = { "GH_PROMPT_DISABLED" => "1", "GH_NO_UPDATE_NOTIFIER" => "1",
                 "GH_STACK_NO_UPDATE_NOTIFIER" => "1", "NO_COLOR" => "1" }.freeze

      REVIEWS = { "APPROVED" => :approved, "CHANGES_REQUESTED" => :changes_requested, "REVIEW_REQUIRED" => :review_required }.freeze

      # Check outcomes the way `gh pr status` buckets them. CheckRun: conclusion once
      # COMPLETED, pending before. StatusContext: state. Anything else (QUEUED,
      # IN_PROGRESS, EXPECTED, PENDING, STALE, ...) is pending.
      PASS = %w[SUCCESS NEUTRAL SKIPPED].freeze
      FAIL = %w[FAILURE ERROR CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE].freeze

      # "no pull requests found" → pr: :none. Any other gh failure (auth, network)
      # raises, which Commands::Fetch turns into SourceFailed (a dimmed `?`).
      def self.fetch(config, slug, branch)
        r = Shell.capture(["gh", "pr", "view", branch, "--json", FIELDS], chdir: config.worktree_path(slug), env: GH_ENV,
                          timeout: config.timeout, stdin: "")
        pr = if r.ok? then parse(r.stdout)
             elsif none?(r) then :none
             else raise Error, "gh pr view: #{r.error_line}"
             end
        Msg::PrLoaded.new(slug:, pr:, at: Time.now)
      end

      def self.none?(result) = !result.timed_out && result.stderr.include?("no pull requests found")

      def self.parse(json)
        data = JSON.parse(json)
        PrStatus.new(number: data.fetch("number"), title: data["title"].to_s, state: data["state"] || "OPEN",
                     draft: data["isDraft"] == true, review: REVIEWS[data["reviewDecision"]], **checks(data["statusCheckRollup"] || []))
      end

      # statusCheckRollup → the PrStatus ci fields. The rollup lists every run on
      # the head commit, so a check re-run (or a run cancelled by a newer one) shows
      # up more than once; only the latest start of each check counts.
      def self.checks(rollup)
        states = latest(rollup).map { [name(it), state(it)] }
        count = ->(s) { states.count { it[1] == s } }
        ci = if states.empty? then :none
             elsif count[:fail].positive? then :fail
             elsif count[:pending].positive? then :pending
             else :pass
             end
        { ci:, ci_passed: count[:pass], ci_failed: count[:fail], ci_total: states.size,
          failing: states.filter_map { |n, s| n if s == :fail }.uniq }
      end

      def self.latest(rollup)
        rollup.group_by { key(it) }.values.map { |runs| runs.max_by { it["startedAt"].to_s } }
      end

      def self.status_context?(check) = check["__typename"] == "StatusContext" || check.key?("context")
      def self.key(check) = status_context?(check) ? [:context, check["context"]] : [:run, check["workflowName"], check["name"]]
      def self.name(check) = (status_context?(check) ? check["context"] : check["name"]).to_s

      def self.state(check)
        value = if status_context?(check) then check["state"]
                elsif check["status"] == "COMPLETED" then check["conclusion"]
                end
        return :pass if PASS.include?(value)
        return :fail if FAIL.include?(value)

        :pending
      end
    end
  end
end
