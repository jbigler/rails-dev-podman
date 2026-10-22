# frozen_string_literal: true

module Dashboard
  module Render
    # What the templates call: the words, glyphs and CSS classes for each cell,
    # and the URLs a worktree's values make. Stateless; one instance is the
    # scope of every render.
    class View
      SERVICE = { up: ["●", "green"], starting: ["◐", "yellow"], stopped: ["○", "muted"], failed: ["✗", "red"], unknown: ["?", "muted"] }.freeze
      # state => [glyph, class, list word]
      AGENT = { permission: ["◆", "accent", "permission"], question: ["◆", "accent", "question"], reply: ["◆", "accent", "waiting for reply"],
                working: ["●", "blue", "working"], your_turn: ["·", "yellow", "your turn"], idle: ["·", "muted", "idle"],
                off: ["○", "muted", "off"] }.freeze
      REVIEW = { approved: ["✓", "green", "approved"], changes: ["✗", "red", "changes requested"],
                 review: ["⟳", "yellow", "review requested"], none: ["⟳", "yellow", "review requested"] }.freeze
      SERVICE_SVC = Workspace::SERVICES.to_h.freeze # label => unit svc
      LOGS = "http://logs.localhost"
      TRAEFIK = "http://127.0.0.1:8080/"
      VNC_QUERY = "path=websockify&autoconnect=1&reconnect=1&reconnect_delay=2000&resize=scale"
      TAIL_CHARS = 600
      JOB = { running: ["●", "blue"], ok: ["✓", "green"], failed: ["✗", "red"], cancelled: ["○", "muted"] }.freeze
      # Lines a running job's fragment carries (it is re-sent with every publish); a finished one carries all.
      RUNNING_TAIL = 500
      # The detail pane's action buttons by group, in order; the restart-<svc> ones sit in the services table.
      ACTION_GROUPS = { "services" => %w[up stop restart-all down], "tests" => %w[test test-rails test-javascript test-system watch-rails watch-javascript],
                        "open" => %w[claude nvim console shell], "share" => %w[share unshare],
                        "stack" => %w[stack-push stack-up stack-down restack], "worktree" => %w[wt-rm] }.freeze

      def dom_id(prefix, name) = Render.dom_id(prefix, name)
      def path(name) = Render.path(name)
      def events_path(name) = Render.events_path(name)
      def row(wt, selected:) = Render.row(wt, selected:)
      def list(state, selected) = Render.list(state, selected)
      def detail(wt, state) = Render.detail(wt, state)
      def header(state, repo:) = Render.header(state, repo:)
      def jobs(state) = Render.jobs(state)

      def logs_home = LOGS
      def traefik_url = TRAEFIK

      def unknown?(value) = value == UNKNOWN

      # HEAD's PR when it was read.
      def head_pr(wt) = wt.pr.is_a?(Pr) ? wt.pr : nil

      # "#<n>" (HTML), a link to the PR when `pr` has a GitHub URL; "" without a number.
      def pr_number(number, pr)
        return "" unless number

        url = pr_url(pr)
        text = "##{Integer(number)}"
        url ? %(<a class="pr-num blue" href="#{ERB::Util.html_escape(url)}" target="_blank" rel="noopener">#{text}</a>) : %(<span class="pr-num blue">#{text}</span>)
      end

      def title(state, repo)
        n = state.needs_input_count
        [("◆ #{n}" if n.positive?), "wt", repo].compact.join(" · ")
      end

      # A stale-units line is "<file>\t<reason>".
      def stale_line(line) = line.split("\t", 2).join(" — ")

      # --- list cells -------------------------------------------------------

      def stack_cell(stack)
        return "?" if stack == UNKNOWN
        return "" unless stack&.position

        "#{stack.position}/#{stack.branches.size}"
      end

      # → [text, class]
      def pr_cell(pr)
        return ["?", "muted"] if pr == UNKNOWN
        return ["", ""] unless pr
        return ["merged", "muted"] if pr.state == :merged

        ["##{pr.number}", pr_class(pr)]
      end

      def pr_class(pr)
        return "muted" if pr.state != :open || pr.draft

        REVIEW.fetch(pr.review, REVIEW[:none])[1]
      end

      # → [glyph, class, word]
      def svc_cell(services)
        summary = Services.summary(services)
        [*SERVICE.fetch(summary), summary.to_s]
      end

      # → [text, class], or nil for an off agent on the base worktree.
      def agent_cell(wt)
        a = wt.agent
        return ["?", "muted"] if a == UNKNOWN
        return nil if a.state == :off && wt.base

        glyph, cls, word = AGENT.fetch(a.state)
        text = a.state == :your_turn && a.since ? "#{word} #{age(a.since)}" : word
        ["#{glyph} #{text}", cls]
      end

      def age(since) = AgentStatus.age(since, Time.now)

      # --- detail: branch, PR, stack -----------------------------------------

      # "↑2 ↓1 origin/x", "?" parts for an unread git status, nil when in sync.
      def sync(wt)
        return "↑? ↓?" if wt.ahead == UNKNOWN || wt.behind == UNKNOWN

        parts = [("↑#{wt.ahead}" if wt.ahead.to_i.positive?), ("↓#{wt.behind}" if wt.behind.to_i.positive?)].compact
        "#{parts.join(' ')} #{wt.upstream.is_a?(String) ? wt.upstream : 'origin'}" unless parts.empty?
      end

      def dirty(wt)
        return "? uncommitted" if wt.dirty_count == UNKNOWN

        "#{wt.dirty_count} uncommitted" if wt.dirty_count.to_i.positive?
      end

      # A stack block when HEAD's branch is in a stack it read.
      def stack?(wt) = wt.stack.is_a?(Stack) && !wt.stack.current_index.nil?

      # → [[text, class]] after the PR title: review, checks, commits.
      def pr_meta(pr)
        [review(pr), checks(pr.checks), commits(pr.commits)].compact
      end

      def review(pr)
        return ["merged", "muted"] if pr.state == :merged
        return ["closed", "muted"] if pr.state == :closed
        return ["draft", "muted"] if pr.draft

        glyph, cls, word = REVIEW.fetch(pr.review, REVIEW[:none])
        ["#{glyph} #{word}", cls]
      end

      def checks(c)
        return nil unless c

        total = c[:pass] + c[:fail] + c[:pending]
        if c[:fail].positive? then ["✗ #{c[:fail]} check#{'s' unless c[:fail] == 1} failing", "red"]
        elsif c[:pending].zero? then ["✓ checks", "green"]
        else ["⟳ #{c[:pass]}/#{total} checks", "yellow"]
        end
      end

      def commits(n)
        return ["? commits", "muted"] if n == UNKNOWN

        ["#{n} commit#{'s' unless n == 1}", "muted"] if n
      end

      def ready?(pr, branch)
        pr.review == :approved && !pr.draft && pr.checks && pr.checks[:fail].zero? && pr.checks[:pending].zero? && !branch.needs_rebase
      end

      # The PR of a stack branch, from either PR list.
      def branch_pr(state, branch) = state.raw.prs[branch] || state.raw.pr_index[branch]

      # Only GitHub's own https URLs become links.
      def pr_url(pr) = pr&.url.to_s.start_with?("https://") ? pr.url : nil

      # → [glyph, class] for a stack branch's open PR, nil without one.
      def review_glyph(pr)
        return nil unless pr&.state == :open
        return ["·", "muted"] if pr.draft

        REVIEW.fetch(pr.review, REVIEW[:none]).first(2)
      end

      # --- detail: agent ------------------------------------------------------

      # The end of the message, whole words, "… " in front when cut.
      def tail(text)
        text = text.to_s.split.join(" ")
        return text if text.length <= TAIL_CHARS

        cut = text[-TAIL_CHARS..]
        "… #{cut.sub(/\A\S*\s/, '')}"
      end

      # The RTK savings chip from the worktree's status file, nil before any rtk command ran.
      # Shows only the fields the file had (Sources::AgentFiles.rtk dropped the bad ones).
      # → [text, tooltip]
      def rtk(state, name)
        r = state.raw.agent_files[name]&.last&.rtk
        return nil unless r&.total_commands&.positive?

        text = ["rtk", ("#{tokens(r.total_saved)} saved" if r.total_saved)].compact.join(" ")
        text += " · #{r.avg_savings_pct.round}%" if r.avg_savings_pct
        flow = [("#{tokens(r.total_input)} raw" if r.total_input), ("#{tokens(r.total_output)} filtered" if r.total_output)].compact
        [text, ["#{r.total_commands.to_i} rtk commands", (flow.join(' → ') if flow.any?)].compact.join(" · ")]
      end

      def tokens(n)
        n = n.to_i
        if n >= 1_000_000 then format("%.1fM", n / 1e6)
        elsif n >= 1000 then format("%.1fK", n / 1e3)
        else n.to_s
        end
      end

      # --- detail: services and links -----------------------------------------

      # → [glyph, class, word]
      def service_state(s)
        glyph, cls = SERVICE.fetch(s.state)
        word = s.state == :up ? (s.health == "healthy" ? "healthy" : "running") : s.state.to_s
        [glyph, cls, word]
      end

      # ":<port>"; "?" when the service has a port but the worktree has no .unit-env yet.
      def port(wt, s)
        return ":#{s.port}" if s.port

        wt.env.empty? && Workspace::PORT_KEYS.key?(SERVICE_SVC[s.label]) ? "?" : ""
      end

      # Dozzle's by-name link; the container is <prefix>-<W>-<svc>, the unit <prefix>-<svc>@<W>.service.
      def logs_url(wt, s)
        svc = SERVICE_SVC.fetch(s.label)
        prefix = s.unit.delete_suffix("-#{svc}@#{wt.name}.service")
        "#{LOGS}/show?name=#{ERB::Util.url_encode("#{prefix}-#{wt.name}-#{svc}")}"
      end

      def rails_up?(wt) = wt.services.is_a?(Array) && wt.services.any? { it.label == "rails" && it.state == :up }

      # → [[label, url]]. Hosts come from .unit-env; without one the host is <W>.localhost.
      def app_links(wt)
        host = wt.env.fetch("WORKTREE_HOST", "").then { it.empty? ? "#{wt.name}.localhost" : it }
        s3_ui = wt.env.fetch("RUSTFS_UI_HOST", "").then { it.empty? ? "s3-ui.#{host}" : it }
        app = "http://#{host}"
        [["app", app], ["mail", "#{app}/letter_opener"], ["lookbook", "#{app}/lookbook"], ["routes", "#{app}/rails/info/routes"],
         ["vnc", "http://vnc.#{host}/vnc.html?#{VNC_QUERY}"], ["rustfs", "http://#{s3_ui}"]]
      end

      # --- actions -------------------------------------------------------------

      # A worktree's buttons are disabled while one of its jobs runs.
      def busy?(state, wt) = state.jobs.any? { it.running? && it.worktree == wt.name }

      STACK_ACTIONS = [*ACTION_GROUPS.fetch("stack"), "stack-switch"].freeze

      # A running stack action of wt's → [text for the stack head, the branch it switches to or nil], else nil.
      def stack_progress(state, wt)
        job = state.jobs.find { it.running? && it.worktree == wt.name && STACK_ACTIONS.include?(it.action) }
        return unless job

        job.action == "stack-switch" ? ["switching to #{job.input}…", job.input] : ["#{job.title}…", nil]
      end

      # → [[group, [Spec]]] for the detail pane; the stack group only on a stack.
      def action_groups(wt)
        offered = Actions.for_worktree(wt).to_h { [it.id, it] }
        ACTION_GROUPS.filter_map do |group, ids|
          specs = offered.values_at(*ids).compact
          [group, specs] unless specs.empty? || (group == "stack" && !wt.stack.is_a?(Stack))
        end
      end

      def action(id) = Actions.find(id)
      def restart_spec(s) = action("restart-#{SERVICE_SVC.fetch(s.label)}")
      def action_path(wt, spec) = "#{path(wt.name)}/act/#{spec.id}"

      # A button the action controller turns into a POST to `url` (HTML); `input`
      # is sent as is (one of the spec's choices).
      def action_button(spec, url, disabled: false, label: spec.label, input: nil, cls: nil, title: nil)
        attrs = { "type" => "button", "class" => cls, "data-action" => "action#run", "data-action-url-param" => url,
                  "data-action-confirm-param" => spec.confirm, "data-action-prompt-param" => spec.prompt,
                  "data-action-input-param" => input, "data-action-discard-param" => ("true" if spec.discardable?),
                  "title" => title || ("opens a terminal" if spec.mode == :terminal) }
        html = attrs.filter_map { |key, value| %( #{key}="#{ERB::Util.html_escape(value)}") unless value.nil? }.join
        %(<button#{html}#{' disabled' if disabled}>#{ERB::Util.html_escape(label)}</button>)
      end

      # A stack branch's name as a button switching the worktree to it (HTML);
      # plain text when the action is not offered here.
      def stack_switch(wt, branch, disabled:)
        spec = Actions.for_worktree(wt).find { it.id == "stack-switch" }
        return ERB::Util.html_escape(branch) unless spec&.choices&.(wt)&.include?(branch)

        action_button(spec, action_path(wt, spec), disabled:, label: branch, input: branch, cls: "stack-switch", title: "switch to #{branch}")
      end

      # → [glyph, class, word]
      def job_status(job)
        glyph, cls = JOB.fetch(job.state)
        word = job.state == :failed && job.exit_status ? "exit #{job.exit_status}" : job.state.to_s
        [glyph, cls, word]
      end

      def duration(job)
        s = [((job.finished_at || Time.now) - job.started_at).to_i, 0].max
        if s < 60 then "#{s}s"
        elsif s < 3600 then format("%dm %02ds", s / 60, s % 60)
        else format("%dh %02dm", s / 3600, s % 3600 / 60)
        end
      end

      # → [lines left out, lines shown]
      def job_lines(job)
        lines = job.running? ? job.lines.last(RUNNING_TAIL) : job.lines
        [job.lines.size - lines.size, lines]
      end

      INSTANCE = new.freeze
    end
  end
end
