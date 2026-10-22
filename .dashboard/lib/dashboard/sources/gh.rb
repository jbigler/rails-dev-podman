# frozen_string_literal: true

module Dashboard
  # gh runs git, so every call carries Sources.git_env of its directory.
  module Sources
    REVIEW = { "APPROVED" => :approved, "CHANGES_REQUESTED" => :changes, "REVIEW_REQUIRED" => :review }.freeze
    PR_STATE = { "OPEN" => :open, "MERGED" => :merged, "CLOSED" => :closed }.freeze

    def self.pr(h, checks: nil)
      Pr.new(number: h["number"], title: h["title"].to_s, state: PR_STATE.fetch(h["state"], :open), draft: h["isDraft"] == true,
             review: REVIEW.fetch(h["reviewDecision"].to_s, :none), checks:, commits: nil, url: h["url"], base_ref: h["baseRefName"])
    end

    def self.gh_pr_list(ws, state, fields)
      argv = ["gh", "pr", "list", "--state", state, "--limit", "200", "--json", fields]
      r = Shell.run(argv, chdir: ws.base_path, timeout: Shell::GH_TIMEOUT, env: git_env(ws.base_path))
      check!(r, "gh pr list").stdout
    end

    # Every open PR of the repo in one call, checks included (no per-PR view).
    module OpenPrs
      FIELDS = "number,headRefName,baseRefName,state,isDraft,reviewDecision,title,url,statusCheckRollup"

      def self.fetch(ws) = parse(Sources.gh_pr_list(ws, "open", FIELDS))

      # branch => Pr with checks. Two open PRs from one branch: the newest wins.
      def self.parse(text)
        Sources.json(text, "gh pr list").sort_by { it["number"].to_i }.to_h do
          [it["headRefName"], Sources.pr(it, checks: Checks.summarize(Array(it["statusCheckRollup"])))]
        end
      end
    end

    # Every PR of the repo, without checks: shows "merged" for a worktree whose
    # branch is done. Fetched on demand only.
    module PrIndex
      FIELDS = "number,headRefName,state,title,url"

      def self.fetch(ws) = parse(Sources.gh_pr_list(ws, "all", FIELDS))

      # branch => Pr. An open PR wins over closed/merged ones; then the newest.
      def self.parse(text)
        Sources.json(text, "gh pr list")
               .sort_by { [it["state"] == "OPEN" ? 1 : 0, it["number"].to_i] }
               .to_h { [it["headRefName"], Sources.pr(it)] }
      end
    end

    # §5.3 checks summary. statusCheckRollup keeps superseded runs, so only the
    # latest run per check counts.
    module Checks
      FAILED = %w[FAILURE TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE CANCELLED].freeze

      # → { pass:, fail:, pending: } or nil when there are no checks.
      def self.summarize(rollup)
        latest = rollup.group_by { key(it) }.values.map { |runs| runs.max_by { (it["startedAt"] || it["completedAt"]).to_s } }
        counted = latest.reject { %w[SKIPPED NEUTRAL].include?(it["conclusion"]) }
        return nil if counted.empty?

        tally = counted.map { classify(it) }.tally
        { pass: tally.fetch(:pass, 0), fail: tally.fetch(:fail, 0), pending: tally.fetch(:pending, 0) }
      end

      def self.key(entry)
        entry["__typename"] == "StatusContext" ? ["ctx", entry["context"]] : ["run", entry["workflowName"], entry["name"]]
      end

      def self.classify(entry)
        if entry["__typename"] == "StatusContext"
          case entry["state"]
          when "SUCCESS" then :pass
          when "FAILURE", "ERROR" then :fail
          else :pending
          end
        elsif entry["status"] != "COMPLETED" then :pending
        elsif entry["conclusion"] == "SUCCESS" then :pass
        elsif FAILED.include?(entry["conclusion"]) then :fail
        else :pending
        end
      end
      private_class_method :key, :classify
    end

    # `gh stack view --json` in one worktree (§3.5).
    module Stack
      def self.fetch(path)
        r = Shell.run(%w[gh stack view --json], chdir: path, timeout: Shell::GH_TIMEOUT, env: Sources.git_env(path))
        raise Failed, "gh stack view: #{r.error_line}" if r.broken?
        return nil unless r.ok? # any other non-zero exit: not in a stack

        parse(r.stdout)
      end

      def self.parse(text)
        h = Sources.json(text, "gh stack view")
        branches = Array(h["branches"]).map do |b|
          StackBranch.new(branch: b["name"], pr_number: b.dig("pr", "number"), pr_state: PR_STATE[b.dig("pr", "state")],
                          current: b["isCurrent"] == true, merged: b["isMerged"] == true, needs_rebase: b["needsRebase"] == true)
        end
        Dashboard::Stack.new(trunk: h["trunk"], current_branch: h["currentBranch"], branches:)
      end
    end
  end
end
