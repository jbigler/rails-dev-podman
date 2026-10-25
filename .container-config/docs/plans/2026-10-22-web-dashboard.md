# Web dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the wt.localhost nginx page (and the abandoned `feature/tui`) with a host-side web dashboard at `http://wt.localhost:<port>` that shows every worktree and runs the workspace's mise tasks.

**Architecture:** One Ruby process (Roda on Falcon, single threaded container) bound to 127.0.0.1, run as the systemd user unit `<prefix>-dashboard.service`. Background threads poll git/systemd/podman/status files (and GitHub only while a page is open) into a `Hub`, which re-derives the worktree model and pushes changed HTML fragments to pages as Turbo Stream messages over SSE. Actions run as `mise run …` children in their own systemd scopes, with output streamed into the page; anything interactive opens a host terminal through `newterm.sh`.

**Tech Stack:** Ruby 4.0.7 (mise), roda ~> 3.109, falcon ~> 0.57, tilt ~> 2.9 + erubi ~> 1.13, rack ~> 3.2; minitest ~> 6.0, rack-test ~> 2.3, rake. Front end: @hotwired/turbo 8.0.23 (`dist/turbo.es2017-esm.js`), @hotwired/stimulus 3.2.2 (`dist/stimulus.js`), vendored, loaded by an import map. No npm, no build step.

**Spec:** `.container-config/docs/specs/2026-10-22-web-dashboard-design.md`. Ported code comes from the `feature/tui` branch: read it with `git show feature/tui:<path>`.

## Global Constraints

- Listen on `127.0.0.1:${WT_DASHBOARD_PORT}` only; default `WT_DASHBOARD_PORT = "7700"` in `.mise/config.toml` `[env]`, overridable in the root `mise.local.toml`.
- Allowed `Host` headers: `wt.localhost:<port>`, `localhost:<port>`, `127.0.0.1:<port>`; anything else → 403, GET and SSE included.
- State-changing requests are POST, carry header `X-Dashboard-Token: <token issued at boot>` and an `Origin` whose host is in the allowed list; else 403.
- Every process is spawned with an argv array, never a shell string, through `Dashboard::Shell` or `Dashboard::Runner`.
- Every git call, and every call of `gh` (which runs git), carries the `GitSafety` environment (Task 2). The dashboard never runs `mise env`.
- Falcon runs exactly one instance: `falcon serve --bind http://127.0.0.1:$WT_DASHBOARD_PORT --threaded --count 1`.
- Read timeouts: 5 s; `gh`: 15 s. Local refresh: worktrees 5 s, git status/units/containers 3 s, status files and `.unit-env` 1 s (on mtime change), stale units + autostart state 60 s.
- GitHub: no call while no page holds the SSE stream; timer 60 s while any open PR has pending checks or a viewed worktree has an open PR, else 300 s; focus/connect hints coalesced (dropped while running or within 10 s of the last refresh); action-triggered refreshes never dropped.
- Retention: last 20 actions in memory, last 5,000 output lines each. One running action per worktree; workspace actions one at a time.
- No `[Install]`-enabled autostart by default: `units:install` never runs `systemctl --user enable`.
- Ruby files: `# frozen_string_literal: true`, module `Dashboard`, files under `.dashboard/lib/dashboard/`, one responsibility each.

## Review Focus

- Worktree names are folder names: the base can be any name (e.g. `master`, `app.v2`). Expect names with dots or other characters to render escaped, link URL-encoded, and get a valid DOM id. → Task 5 test `test_unusual_worktree_name`.
- A page left open on a worktree that `wt:rm` removed: expect `/w/<gone>` to redirect to `/`, and the open page's detail to be replaced with "worktree removed", never a 500. → Task 6 test `test_vanished_worktree`.
- Action output that is huge, has ANSI escapes, or is invalid UTF-8 (test runners, `podman build`): expect it shown scrubbed, without crashing the stream. → Task 7 test `test_output_is_scrubbed`.
- The dashboard restarts while a page is open: the page's token is now wrong. Expect the next POST to get 403 with `X-Dashboard-Reload: 1` and the page to reload itself, not silently ignore the click. → Task 5 test `test_stale_token_asks_for_reload`.
- Palette arguments with an unbalanced quote (`-n "foo`): expect a 422 with the parse error shown, not a 500 or a run with mangled args. → Task 8 test `test_palette_unbalanced_quote`.

## File map

```
.dashboard/
  .bundle/config            BUNDLE_PATH: vendor/bundle (committed)
  Gemfile, Gemfile.lock, Rakefile, config.ru
  lib/dashboard.rb          require order
  lib/dashboard/
    shell.rb                Shell, Shell::Result, Shell::Real                (Task 2)
    git_safety.rb           GitSafety.env(path)                              (Task 2)
    workspace.rb            Workspace                                        (Task 3)
    model.rb                value objects                                    (Task 3)
    sources/git.rb          Worktrees, GitStatus, Repo, CommitCount          (Task 3)
    sources/local.rb        UnitEnv, Units, Containers, AgentFiles, StaleUnits, Autostart (Task 3)
    sources/gh.rb           OpenPrs, PrIndex, Checks, Stack                  (Task 3)
    sources/tasks.rb        Tasks                                            (Task 3)
    services.rb, agent_status.rb, derive.rb                                  (Task 3)
    schedule.rb             Schedule (pure)                                  (Task 4)
    hub.rb                  Hub, Subscription                                (Task 4)
    pollers.rb              LocalPoller, GithubPoller (threads)              (Task 4)
    render.rb               Render (Tilt/Erubi fragments)                    (Task 5)
    guard.rb                Guard (Rack middleware)                          (Task 5)
    app.rb                  App (Roda)                                       (Task 5, 6, 7, 8)
    streams.rb              Streams (Turbo Stream / SSE framing)             (Task 6)
    session_env.rb          SessionEnv.current                               (Task 7)
    runner.rb               Runner, Job                                      (Task 7)
    actions.rb              Actions registry                                 (Task 7)
    palette.rb              Palette                                          (Task 8)
  views/                    layout.erb, page.erb, _header.erb, _row.erb, _detail.erb, _job.erb, _palette.erb
  public/                   app.css, app.js, controllers/*.js, vendor/turbo.es2017-esm.js, vendor/stimulus.js
  test/                     test_helper.rb, *_test.rb, fixtures/ (from feature/tui), hook/
.container-config/systemd/dashboard.service                                  (Task 10)
.scripts/dashboard-isolation-check.sh                                        (Task 1)
.scripts/newterm.sh, .scripts/claude-newterm.sh                              (Task 8)
```

---

### Task 1: Isolation check (gate for everything after it)

**Files:**
- Create: `.scripts/dashboard-isolation-check.sh`
- Modify: `.mise/config.toml` (env `WT_DASHBOARD_PORT = "7700"`; task `dashboard:isolation-check`)

**Interfaces:**
- Produces: `.scripts/dashboard-isolation-check.sh` — exit 0 when no probe connects, 1 when any does, 2 when it cannot probe. Task 11 calls it from `quadlet.sh verify`.

- [ ] **Step 1: Write the script.** Behaviour:
  - Needs `PROJECT_PREFIX` and `WT_DASHBOARD_PORT` (mise env). If nothing listens on `127.0.0.1:$WT_DASHBOARD_PORT`, start a throwaway listener (`ruby -rsocket -e 'TCPServer.new("127.0.0.1", ARGV[0].to_i).then { |s| loop { s.accept.close } }' "$port" &`) and kill it on EXIT.
  - Probe image: the `RAILS_IMAGE` from the first `.unit-env/*.env` for which `podman image exists` succeeds (it has bash); none → exit 2 with "build an image first: mise run build".
  - Throwaway probes: `podman run --rm --network "${PROJECT_PREFIX}_proxy" "$img" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/$0/$1"' <target> "$port"` for each target: `host.containers.internal`, the proxy gateway (`podman network inspect "${PROJECT_PREFIX}_proxy" --format '{{range .Subnets}}{{.Gateway}}{{end}}'`), `169.254.1.2`, `10.0.2.2`. Repeat the four on each existing `${PROJECT_PREFIX}-*-dev` network.
  - Running playwright containers (`podman ps --filter name=^${PROJECT_PREFIX}-.*-playwright$ --format '{{.Names}}'`): `podman exec <ct> bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/$0"' "$port"`, and the same with `wt.localhost` via `getent hosts wt.localhost` inside the container.
  - A probe "connects" when the inner bash exits 0. Print one line per probe: `blocked  <where> -> <target>:<port>` or `REACHED  …`. Exit 1 if any reached.
- [ ] **Step 2: Add the task** `[tasks."dashboard:isolation-check"]` running the script from `{{config_root}}`.
- [ ] **Step 3: Syntax check.** Run `bash -n .scripts/dashboard-isolation-check.sh && shellcheck .scripts/dashboard-isolation-check.sh` (shellcheck if installed). Expected: no output.
- [ ] **Step 4: Commit** `git commit -m "dashboard: isolation check for the dashboard port"`.
- [ ] **Step 5: HOST GATE.** This sandbox has no podman. Ask the user to run `mise run dashboard:isolation-check` on the host and paste the output. Every line must read `blocked`. Any `REACHED` → stop and bring it to the user; do not start Task 2.

### Task 2: App scaffold, Shell, GitSafety

**Files:**
- Create: `.dashboard/{Gemfile,Gemfile.lock,Rakefile,config.ru,.bundle/config}`, `.dashboard/lib/dashboard.rb`, `.dashboard/lib/dashboard/{shell.rb,git_safety.rb}`, `.dashboard/test/{test_helper.rb,shell_test.rb,git_safety_test.rb}`
- Modify: `.mise/config.toml` (tasks `dashboard:serve`, `dashboard:test`)

**Interfaces:**
- Produces:
  - `Dashboard::Shell.run(argv, chdir: nil, timeout: Shell::TIMEOUT, env: {}) -> Shell::Result`; `Shell::TIMEOUT = 5`, `Shell::GH_TIMEOUT = 15`; `Shell.backend=` for tests.
  - `Shell::Result = Data(:stdout, :stderr, :status, :timed_out)` with `ok?`, `broken?`, `error_line` (port `feature/tui:.tui/lib/wt/shell.rb`, minus `foreground`/`osc52`).
  - `Dashboard::GitSafety.env(path) -> Hash{String=>String}`: `GIT_OPTIONAL_LOCKS=0` plus `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` for `core.fsmonitor=false`, `core.hooksPath=/dev/null`, and an empty value for every key printed by `git -C <path> config --name-only --get-regexp '^filter\..*\.(clean|smudge|process)$'` (that read itself runs with only the first two overrides). May cache per path by the mtimes of `<git common dir>/config` and `<git dir>/config.worktree`.
  - `test/test_helper.rb`: `FakeShell` (port from `feature/tui:.tui/test/test_helper.rb`, minus ratatui; its `Call` records `argv`, `chdir` and `env`), `fixture(*path)`, `fixture_raw` (adapted to the new `Raw` in Task 3), `ROOT = "/home/dev/workspace/myproj"`, `NOW = Time.utc(2026, 10, 20, 14, 3, 0)`.

- [ ] **Step 1: Gemfile, `.bundle/config` (`BUNDLE_PATH: "vendor/bundle"`), Rakefile** (`test` task over `test/**/*_test.rb`; `hook` task added in Task 9; `default: :test`). `bundle install` and commit the lock.
- [ ] **Step 2: Write the failing tests.**
  - `test_missing_binary_is_status_127`: `Shell::Real.new.run(["no-such-binary-xyz"])` → `status == 127`, `broken?`.
  - `test_timeout_kills_the_group`: `run(["sh", "-c", "sleep 5 & sleep 5"], timeout: 0.3)` → `timed_out`, returns in < 2 s.
  - `test_filter_driver_never_runs` (real git in a `Dir.mktmpdir`): repo with `.gitattributes` `*.txt filter=evil`, committed `a.txt` = `hi`; then `git config filter.evil.clean 'sh -c "touch <dir>/PWNED; cat"'`; rewrite `a.txt` to `hu\n` and reset its mtime to the original second (`File.utime`), which forces git to re-hash. `Shell.run(["git", "-C", dir, "status", "--porcelain=v2"], env: GitSafety.env(dir))` → `refute File.exist?("#{dir}/PWNED")`. Sanity: the same status without the env creates `PWNED` (assert it, so the test proves the attack works).
  - `test_fsmonitor_and_hooks_overridden`: `GitSafety.env(dir)` includes the pairs `core.fsmonitor`→`false`, `core.hooksPath`→`/dev/null`, and `GIT_OPTIONAL_LOCKS=0`.
- [ ] **Step 3: Run** `mise run dashboard:test`. Expected: FAIL (undefined constants).
- [ ] **Step 4: Implement** `shell.rb`, `git_safety.rb`, `lib/dashboard.rb` (requires json, time, open3, then the files in layer order), `config.ru` (`require_relative "lib/dashboard"; run Dashboard::App.boot` — `App.boot` arrives in Task 5; until then `run ->(_) { [200, {}, ["ok"]] }`).
- [ ] **Step 5: Tasks.** `dashboard:serve`: `dir = "{{config_root}}/.dashboard"`, `tools = { ruby = "4.0.7" }`, run `bundle check >/dev/null 2>&1 || bundle install --quiet` then `exec bundle exec falcon serve --bind "http://127.0.0.1:${WT_DASHBOARD_PORT}" --threaded --count 1`. `dashboard:test`: same dir/tools, `bundle exec rake`.
- [ ] **Step 6: Run** `mise run dashboard:test`. Expected: 4 runs, 0 failures.
- [ ] **Step 7: Commit** `git commit -m "dashboard: scaffold, shell adapter, git safety environment"`.

### Task 3: Sources, model, derivation (ported)

**Files:**
- Create: `.dashboard/lib/dashboard/{workspace,model,services,agent_status,derive}.rb`, `.dashboard/lib/dashboard/sources/{git,local,gh,tasks}.rb`, `.dashboard/test/{sources_test,derive_test}.rb`, `.dashboard/test/fixtures/` (copy of `feature/tui:.tui/test/fixtures/`, plus `gh-pr-list-open.json` and `unit-env.wt-stacked.env`)

**Interfaces:**
- Consumes: `Shell.run`, `GitSafety.env` (Task 2).
- Produces (port from `feature/tui:.tui/lib/wt/` — `workspace.rb`, `model.rb` minus `Overlay`/`Toast`/`Busy`/`Tasks`/`Model`, `sources/*.rb`, `services.rb`, `agent_status.rb`, `derive.rb` — with these changes):
  - `Workspace.discover(env: ENV, cwd: Dir.pwd)`; `Workspace::SERVICES` gains `%w[nvim nvim]`; `PORT_KEYS` gains `"nvim" => "NVIM_PORT"`; new `#unit_env_file(name) = "<root>/.unit-env/<name>.env"`, `#port`, `#dashboard_unit = "<prefix>-dashboard.service"`.
  - `Raw = Data(:refs, :git, :env, :units, :containers, :agent_files, :prs, :pr_index, :commits, :stacks, :stale_units, :autostart)`; `pr_detail` is gone.
  - `Pr` gains `:url`, `:base_ref`. `StatusFile` gains `:rtk` (the hook's RTK savings hash, shown as the chip the old page had).
  - `Sources::UnitEnv.parse(text) -> Hash` of `KEY=VALUE` lines (comments/blank skipped) sliced to `WORKTREE_HOST S3_HOST RUSTFS_UI_HOST APP_PORT DB_PORT S3_PORT PLAYWRIGHT_HOST_PORT NVIM_PORT`; `UnitEnv.fetch(ws, names, known_mtimes) -> {changed:, gone:}` like `AgentFiles`. Replaces `Sources::Env`.
  - `Sources::OpenPrs.fetch(ws) -> {branch => Pr}`: `gh pr list --state open --limit 200 --json number,headRefName,baseRefName,state,isDraft,reviewDecision,title,url,statusCheckRollup`, checks via `Checks.summarize`.
  - `Sources::PrIndex.fetch(ws) -> {branch => Pr}`: `--state all --limit 200 --json number,headRefName,state,title,url`, open wins, then newest (the old `PrList.parse` rule).
  - `Sources::CommitCount.fetch(path, base_ref) -> Integer | nil`: `git rev-list --count origin/<base_ref>..HEAD`.
  - `Sources::StaleUnits.fetch(ws) -> [String]` (lines of `quadlet.sh check-stale` stderr naming units; empty when exit 0); `Sources::Autostart.fetch(ws) -> :enabled | :disabled | :unknown` from `systemctl --user is-enabled <dashboard_unit>`.
  - Every git/gh invocation passes `env: GitSafety.env(<path>)`.
  - `Derive.worktrees(ws, raw, failed) -> [Worktree]`: PR = `raw.prs[branch]` (open, with checks) else `raw.pr_index[branch]`; `commits` filled from `raw.commits[name]`.
  - `Services.for` returns six services (nvim last); `Services.summary` unchanged.
- [ ] **Step 1: Copy fixtures; build** `gh-pr-list-open.json` = JSON array of the object in `gh-pr-view.wt-stacked.json` (add `"url"`) plus the `OPEN` entries of `gh-pr-list.json` with `"statusCheckRollup": []`; `unit-env.wt-stacked.env` = `WORKTREE_HOST=wt-stacked.localhost`, `APP_PORT=13022`, `DB_PORT=55454`, `NVIM_PORT=17022`, a comment line, a blank line.
- [ ] **Step 2: Port the tests** from `feature/tui:.tui/test/sources_test.rb` and the derivation/agent cases of `state_test.rb`, adapted to the names above, and add:
  - `test_open_prs_carry_checks`: `OpenPrs.parse(fixture("gh-pr-list-open.json"))["feature/branch-72"].checks` == `{pass: N, fail: 0, pending: 0}` with N the fixture's latest-run successes (the approved PR must not read as failing).
  - `test_unit_env_keys`: `UnitEnv.parse(fixture("unit-env.wt-stacked.env"))` == `{"WORKTREE_HOST"=>"wt-stacked.localhost","APP_PORT"=>"13022","DB_PORT"=>"55454","NVIM_PORT"=>"17022"}`.
  - `test_stopped_worktrees_listed`: `Derive.worktrees` on the fixture raw returns all 16 names (base `master` last) and a stopped one has every service `:stopped`.
  - `test_six_services_with_nvim`: labels == `%w[rails postgres redis rustfs playwright nvim]`.
  - `test_git_calls_carry_safety_env`: with a FakeShell recording `env`, `GitStatus.fetch` and `OpenPrs.fetch` calls include `GIT_CONFIG_COUNT`.
- [ ] **Step 3: Run** `mise run dashboard:test`. Expected: FAIL.
- [ ] **Step 4: Port and adapt** the files listed above.
- [ ] **Step 5: Run** `mise run dashboard:test`. Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "dashboard: port worktree, pod, gh and status sources from feature/tui"`.

### Task 4: Schedule, Hub, pollers

**Files:**
- Create: `.dashboard/lib/dashboard/{schedule,hub,pollers}.rb`, `.dashboard/test/{schedule_test,hub_test}.rb`

**Interfaces:**
- Consumes: sources, `Derive` (Task 3).
- Produces:
  - `Schedule.new(now)`; `#local_due(now) -> [Symbol]` from `:worktrees`(5) `:git`(3) `:units`(3) `:containers`(3) `:agent_files`(1) `:unit_env`(1) `:stale_units`(60) `:autostart`(60); `#github_due?(now, subscribers:, hot:) -> bool` (`hot` = pending checks anywhere or a viewed worktree with an open PR; interval 60 if hot else 300; false when `subscribers == 0`); `#hint(now, kind)` with `kind` `:focus | :action` → `:run | :drop | :queued`; `#github_started(now)`, `#github_finished(now) -> bool` (true = run again, a queued action refresh).
  - `Hub.new(ws)`; `#apply(key, value, failed: false)`; `#snapshot -> State` (`State = Data(:worktrees, :raw, :failed, :jobs)`); `#subscribe(viewing:) -> Subscription` (`Subscription#queue` a `Thread::Queue`, `#viewing`); `#unsubscribe(sub)`; `#view(sub, name)`; `#viewed_names -> Set`; `#subscriber_count`. On every change it diffs old vs new worktrees and pushes events to subscriber queues: `[:row, name]` to all, `[:detail, name]` only to subscribers viewing `name`, `[:header]` when the attention count, `raw.stale_units` or `raw.autostart` changed, `[:notify, name]` when a worktree's agent enters `:permission` or `:question`, `[:job, id]` on job output/state changes, `[:gone, name]` when a viewed name disappears.
  - `LocalPoller.new(hub, ws, schedule).start` and `GithubPoller.new(hub, ws, schedule).start`: threads; GitHub fetches never run on the local thread. `GithubPoller#hint(kind)` is what `POST /refresh` and the runner call.
- [ ] **Step 1: Write the failing tests** (fake clock = plain `Time` values):
  - `test_no_github_without_pages`: `github_due?(t0 + 3600, subscribers: 0, hot: true)` false.
  - `test_hot_interval_60`: after `github_started(t0)`/`github_finished(t0)`, due at `t0+60` not at `t0+59` with `hot: true`; with `hot: false` due at `t0+300` not `t0+299`.
  - `test_focus_hints_coalesce`: `hint(t0, :focus)` → `:run`; after `github_finished(t0)`, `hint(t0+5, :focus)` → `:drop`, `hint(t0+11, :focus)` → `:run`; while running, `:drop`.
  - `test_action_hint_queues`: while running, `hint(t, :action)` → `:queued`; `github_finished(t)` → `true`.
  - `test_detail_events_only_to_viewers`: two subscriptions viewing `wt-01` and `wt-stacked`; applying a git status change for `wt-stacked` puts `[:detail, "wt-stacked"]` only on the second queue and `[:row, "wt-stacked"]` on both.
  - `test_notify_on_question`: applying a status file whose phase goes `working` → `question` (container running) enqueues `[:notify, name]` once; applying the same file again enqueues nothing.
  - `test_gone_when_viewed_worktree_removed`: applying refs without `wt-01` enqueues `[:gone, "wt-01"]` to its viewer.
- [ ] **Step 2: Run** `mise run dashboard:test`. Expected: FAIL.
- [ ] **Step 3: Implement** `schedule.rb` (pure, no threads), `hub.rb` (one `Mutex`; derive outside the lock is fine as long as `apply` is serialized), `pollers.rb` (loop: `sleep 0.25`, ask the schedule, fetch, `hub.apply`; a raised `Sources::Failed` → `hub.apply(key, nil, failed: true)`). `:commits` fetched by the GitHub poller for viewed worktrees with an open PR. `:stacks` fetched for viewed worktrees only.
- [ ] **Step 4: Run** `mise run dashboard:test`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "dashboard: refresh schedule, hub and pollers"`.

### Task 5: Page, fragments, guard

**Files:**
- Create: `.dashboard/lib/dashboard/{render,guard,app}.rb`, `.dashboard/views/{layout,page,_header,_row,_detail}.erb`, `.dashboard/public/{app.css,app.js}`, `.dashboard/public/vendor/{turbo.es2017-esm.js,stimulus.js}`, `.dashboard/test/{app_test,render_test}.rb`
- Modify: `.dashboard/config.ru`

**Interfaces:**
- Consumes: `Hub#snapshot`, `Worktree` etc.
- Produces:
  - `Render.row(wt, selected:) / .detail(wt, state) / .header(state) / .page(state, selected) -> String` (Tilt + Erubi, `escape_html: true`, templates compiled once).
  - `Render.dom_id(prefix, name) -> String`: `"#{prefix}-" + name.gsub(/[^A-Za-z0-9_-]/) { format("_%02x", it.ord) }`. Ids: `row-<n>`, `detail`, `header`, `actions`, `job-<id>`.
  - `Guard.new(app, port:, token:)` Rack middleware: Host check (403 body "forbidden host"); for POST: `Origin` host in the allowed list and `X-Dashboard-Token == token`, else 403 with header `X-Dashboard-Reload: 1` when the Origin is valid but the token is wrong.
  - `App.boot -> Rack app`: builds `Workspace.discover`, `Hub`, pollers, `Runner` (Task 7), token = `SecureRandom.hex(32)`, port from `ENV.fetch("WT_DASHBOARD_PORT")`. `App.build(hub:, runner:, token:, port:, ws:)` for tests.
  - Routes now: `GET /healthz` → `ok`; `GET /` → 302 `/w/<first worktree>`; `GET /w/:name` → page, unknown name → 302 `/`; static `/assets/*` from `public/`.
- Layout: `<meta name="dashboard-token">`, import map `{"@hotwired/turbo": "/assets/vendor/turbo.es2017-esm.js", "@hotwired/stimulus": "/assets/vendor/stimulus.js"}`, `<script type="module" src="/assets/app.js">`. Page per the spec's Screen section: header (repo, need-input count also in `<title>`, stale-units banner, logs.localhost and `http://127.0.0.1:8080/` links), list (all worktrees, columns name/branch/stack k/n/PR #/services glyph/agent), detail (branch line with a copy-branch button, PR or stack top-down with HEAD expanded and merged collapsed, PR numbers linking to `Pr#url`, agent block with the last-message tail and the RTK chip, services with state, port and a `logs` link to `http://logs.localhost` (deep-linked to the container if Dozzle supports it), app links from `env` — `http://<WORKTREE_HOST>`, `/letter_opener`, `/lookbook`, `/rails/info/routes`, `http://vnc.<WORKTREE_HOST>/vnc.html?path=websockify&autoconnect=1&reconnect=1&reconnect_delay=2000&resize=scale`, `http://<RUSTFS_UI_HOST>` — disabled while rails is not `:up`; host falls back to `<name>.localhost` with no `.unit-env`), action-panel container. Unknown cells (`UNKNOWN`) render `?`. CSS: Flexoki tokens from `feature/tui:.tui/lib/wt/theme.rb` as custom properties, dark via `prefers-color-scheme`.
- [ ] **Step 1: Vendor Turbo and Stimulus**: download `https://registry.npmjs.org/@hotwired/turbo/-/turbo-8.0.23.tgz` and `…/@hotwired/stimulus/-/stimulus-3.2.2.tgz`, extract the two dist files into `public/vendor/`, keep their license headers.
- [ ] **Step 2: Write the failing tests** (rack-test on `App.build` with a hub fed `fixture_raw`, `port: 7700`, `token: "t"`):
  - `test_lists_every_worktree`: `GET /w/wt-stacked` with `Host: wt.localhost:7700` → 200, body has 16 `id="row-…"` rows, `◀ HEAD`, `✓ 5 merged`.
  - `test_rejects_foreign_host`: `Host: evil.example:7700` → 403; `Host: wt.localhost:80` → 403; `GET /healthz` with `Host: 127.0.0.1:7700` → 200.
  - `test_post_needs_token_and_origin`: `POST /refresh` with good Host but no token → 403; token `t` but `Origin: http://evil.example` → 403; both good → 2xx.
  - `test_stale_token_asks_for_reload`: good Origin, token `old` → 403 with `X-Dashboard-Reload: 1`.
  - `test_unusual_worktree_name`: a ref named `app.v2<x>` renders as `app.v2&lt;x&gt;`, links to `/w/app.v2%3Cx%3E`, and has id `row-app_2ev2_3cx_3e`.
  - `test_unknown_worktree_redirects`: `GET /w/nope` → 302 `/`.
- [ ] **Step 3: Run** `mise run dashboard:test`. Expected: FAIL.
- [ ] **Step 4: Implement** render, guard, app, views, CSS, `app.js` (imports Turbo and Stimulus, starts the Stimulus application; controllers are registered in Tasks 6–8). `config.ru`: `run Dashboard::App.boot`.
- [ ] **Step 5: Run** `mise run dashboard:test`. Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "dashboard: page, fragments and request guard"`.

### Task 6: Live updates over SSE

**Files:**
- Create: `.dashboard/lib/dashboard/streams.rb`, `.dashboard/public/controllers/{focus_controller,notify_controller}.js`, `.dashboard/test/streams_test.rb`
- Modify: `app.rb`, `views/layout.erb`, `public/app.js`

**Interfaces:**
- Consumes: `Hub#subscribe/#view/#unsubscribe`, Hub events (Task 4), `Render` (Task 5), `GithubPoller#hint`.
- Produces:
  - `Streams.turbo(action, target, html = nil, **attrs) -> String` (`<turbo-stream action=… target=…><template>…</template></turbo-stream>`), `Streams.sse(payload) -> String` (each line prefixed `data: `, ends with a blank line), `Streams.frames(event, state, sub) -> [String]` mapping `[:row, n]`→replace `row-<n>`, `[:detail, n]`→replace `detail`, `[:header]`→replace `header`, `[:job, id]`→replace `job-<id>` (append to `actions` if new), `[:gone, n]`→replace `detail` with a "worktree removed" notice, `[:notify, n]`→`<turbo-stream action="notify" title="<n>: needs permission|question" body="<message>" tag="<n>">`.
  - `GET /events?w=<name>`: Rack 3 streaming body (`proc { |stream| … }`, `content-type: text/event-stream`, `cache-control: no-store`); subscribes, sends an SSE comment `: ping` every 15 s, unsubscribes in `ensure`. A connect also sends `GithubPoller#hint(:focus)`.
  - `POST /refresh` (form `w`): `hub.view(...)` not needed; just `GithubPoller#hint(:focus)` → 204.
  - `focus_controller.js` on `<body>`: on `visibilitychange` to visible, POST `/refresh` with the token; on a 403 with `X-Dashboard-Reload: 1`, `location.reload()`.
  - `notify_controller.js`: registers `Turbo.StreamActions.notify` (creates `new Notification(title, {body, tag})` when permission is granted); a header button asks for permission.
- [ ] **Step 1: Write the failing tests:**
  - `test_sse_framing`: `Streams.sse("<a>\n<b>")` == `"data: <a>\ndata: <b>\n\n"`.
  - `test_detail_frame_targets_detail`: `Streams.frames([:detail, "wt-stacked"], state, sub)` is one string containing `action="replace" target="detail"` and `◀ HEAD`.
  - `test_vanished_worktree`: `frames([:gone, "wt-01"], …)` replaces `detail` with text `worktree removed`; `GET /w/wt-01` after the refs no longer contain it → 302 `/`.
  - `test_events_stream_delivers_row_updates`: start `GET /events?w=wt-01` against `App.build` in a thread with a stream double collecting writes; apply a git status change for `wt-01`; within 1 s the collected output contains `target="row-wt-01"`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "dashboard: live updates as Turbo Streams over SSE"`.

### Task 7: Actions: registry, runner, session environment

**Files:**
- Create: `.dashboard/lib/dashboard/{session_env,runner,actions}.rb`, `.dashboard/views/_job.erb`, `.dashboard/public/controllers/{action_controller,panel_controller,clipboard_controller}.js`, `.dashboard/test/{runner_test,actions_test}.rb`
- Modify: `app.rb`, `views/_detail.erb`, `views/_header.erb`

**Interfaces:**
- Consumes: `Hub` (job events), `GithubPoller#hint(:action)`, `Workspace`.
- Produces:
  - `SessionEnv.current -> Hash`: from `systemctl --user show-environment`, the keys `SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_RUNTIME_DIR KITTY_LISTEN_ON` that are set, plus `NO_COLOR=1`.
  - `Job = Struct(:id, :worktree, :label, :state, :exit_status, :started_at, :finished_at, :lines, :created)`; `state` `:running | :ok | :failed | :cancelled`; `created` is the worktree name a successful `wt-create` added (the refs after minus the refs before), and its job fragment links to `/w/<created>`; `action_controller.js` visits that link when the job was started from the same page ("select it when done").
  - `Runner.new(hub:, ws:, spawner: Runner::Spawn.new)`; `#start(spec, worktree:, input: nil, discard: false) -> Job` (raises `Runner::Busy` when the worktree — or for workspace actions, the workspace — already has a running job); `#cancel(id)`; `#jobs`. Stream mode: each argv runs as `["systemd-run", "--user", "--scope", "--collect", "--quiet", "--", *argv]` with `pgroup: true`, `in: File::NULL`, env `SessionEnv.current.merge(spec.env)`, stdout+stderr merged, read line by line; a spec with several argvs runs them in order and stops at the first failure. Lines: ANSI escapes stripped (`/\e\[[0-9;?]*[ -\/]*[@-~]/`), `String#scrub("?")`, last 5,000 kept. Cancel sends TERM then KILL to the process group. Terminal mode: one call `[ws.newterm, "--title", "<W>: <label>", "--cwd", <cwd>, "--", *argv]` wrapped in the same `systemd-run --scope`, recorded as a job with the newterm result.
  - On finish: `hub` gets `[:job, id]`; specs with `github: true` call `GithubPoller#hint(:action)`; every finish triggers an immediate local refresh.
  - `Actions::Spec = Data(:id, :label, :mode, :scope, :argv, :env, :confirm, :github, :base_ok)`; `argv` is a lambda `(ws, wt, input) -> [[String]]`. `Actions.find(id)`, `Actions.for_worktree(wt)`. The registry (ids exact; `mise` = `["mise", "run", …]`):

    | id | mode | argv / notes |
    | --- | --- | --- |
    | `up`, `stop` | stream | `mise run up` / `stop` |
    | `down` | stream, confirm | `mise run down`, env `FORCE=1` |
    | `restart-<svc>` for `rails db redis rustfs playwright nvim` | stream | `mise run restart <svc>` |
    | `restart-all` | stream | `mise run stop`, then `mise run up` |
    | `test`, `test-rails`, `test-javascript`, `test-system` | stream | `mise run test` / `test:rails` / `test:javascript` / `test:rails_system` |
    | `watch-rails`, `watch-javascript` | terminal | `mise run test:rails_watcher` / `test:javascript_watcher` |
    | `nvim`, `console`, `shell` | terminal | `mise run nvim` / `console` / `rails` |
    | `claude` | terminal | `podman attach <P>-<W>-claude` when that container is running, else `mise run claude` |
    | `share`, `unshare` | stream | `mise run wt:share` / `wt:unshare` |
    | `stack-push`, `stack-up`, `stack-down` | stream, github | `gh stack push` / `up` / `down` |
    | `restack` | terminal | `gh stack rebase` |
    | `wt-rm` | stream, confirm, scope workspace, cwd root, `base_ok: false`, github | `mise run wt:rm <W>`; env `FORCE=1` only when `discard` |
    | `wt-create` | stream, scope workspace, cwd root, input required, github | `mise run wt <input>` |
    | `units-install` | stream, scope workspace, cwd root | `mise run units:install` |
    | `autostart-on`, `autostart-off` | stream, scope workspace, cwd root | `mise run dashboard:autostart on` / `off` |

  - Routes: `POST /w/:name/act/:id` (form `input`, `discard`) → 202 with the job id, 409 on `Busy`, 422 when `base_ok` is false on the base worktree or a required input is blank; `POST /act/:id` for workspace specs; `POST /jobs/:id/cancel` → 204.
  - Front end: `action_controller.js` (POST with the token; `data-confirm` text → `confirm()`; `data-prompt` → `prompt()`; the `wt-rm` dialog has a "discard uncommitted changes" checkbox; reload on `X-Dashboard-Reload`), `panel_controller.js` (collapse, autoscroll the running job), `clipboard_controller.js` (copy branch name).
- [ ] **Step 1: Write the failing tests** (`Runner` with a fake spawner that yields scripted lines and an exit status):
  - `test_one_job_per_worktree`: starting `up` twice on `wt-01` → second raises `Runner::Busy`; `up` on `wt-02` meanwhile is fine.
  - `test_down_is_forced`: `Actions.find("down").env` == `{"FORCE"=>"1"}`; `wt-rm` without `discard` has no `FORCE`, with `discard` has `FORCE=1`.
  - `test_wt_rm_refused_on_base`: `POST /w/master/act/wt-rm` → 422.
  - `test_scope_wrapping`: the real `Spawn` argv for `up` starts with `systemd-run --user --scope --collect --quiet --` and ends with `mise run up` (assert on the argv the spawner receives, no process run).
  - `test_restart_all_stops_on_failure`: `stop` fails → `up` never spawned, job `:failed`.
  - `test_output_is_scrubbed`: spawner yields `"\e[31mred\e[0m"`, `"\xff\xfe".b`, and 6,000 lines → stored lines read `red`, `??`, and `lines.size == 5000` ending with the last line.
  - `test_github_hint_after_stack_push`: finishing `stack-push` calls the poller double's `hint(:action)`.
  - `test_session_env_from_manager`: FakeShell `systemctl --user show-environment` → `DISPLAY=:0\nSSH_AUTH_SOCK=/run/user/1000/ssh\nFOO=x\n` gives `{"DISPLAY"=>":0","SSH_AUTH_SOCK"=>"/run/user/1000/ssh","NO_COLOR"=>"1"}`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** session env, runner (one reader thread per job), actions, routes, `_job.erb`, buttons in `_detail.erb` / `_header.erb` (busy state disables a worktree's buttons; the autostart switch shows `Raw#autostart`). **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `git commit -m "dashboard: actions with streamed output in their own scopes"`.

### Task 8: Palette and terminals (newterm.sh)

**Files:**
- Create: `.dashboard/lib/dashboard/palette.rb`, `.dashboard/views/_palette.erb`, `.dashboard/public/controllers/palette_controller.js`, `.dashboard/test/palette_test.rb`
- Create/Modify: `.scripts/newterm.sh`, `.scripts/claude-newterm.sh` (take both from `git show feature/tui:<path>`; commit `cd708ac`)
- Modify: `app.rb`

**Interfaces:**
- Consumes: `Sources::Tasks` (Task 3), `Runner` (Task 7).
- Produces:
  - `Palette.tasks(ws, path) -> [MiseTask]` cached 60 s; `Palette.mode(task_name) -> :stream | :terminal`; `Palette::TERMINAL` (initial list — confirm each against its `run` in `.mise/config.toml` by looking for `read`, `gum`, `-it`, `exec podman logs -f`, `--remote-ui`, interactive shells, and adjust): `claude claude:newterm claude:notoken claude:notoken:newterm console nvim rails exec logs proxy:logs test:rails_watcher test:javascript_watcher down destroy clean`.
  - `Palette.argv(task, input) -> [String]` = `["mise", "run", task.name, *Shellwords.split(input)]`; raises `Palette::BadArgs` with the Shellwords message on unbalanced quotes; raises `Palette::BadArgs` "arguments required" when `Tasks.args(task.usage) == :required` and the input is blank. `POST /w/:name/palette` runs it through `Runner#start` with an ad-hoc `Actions::Spec` (`id: "palette:<task>"`, `mode: Palette.mode(name)`, `scope: :worktree`, `argv: ->(*) { [argv] }`, `env: {}`, `github: true`).
  - `GET /palette?w=<name>` → `_palette.erb` list (name, description, argument kind); `POST /w/:name/palette` (form `task`, `args`) → 202 job id; `BadArgs` → 422 with the message.
  - `palette_controller.js`: opens on a header button and `:`/Ctrl-K, fuzzy subsequence filter on the name, Enter runs, prompts for args when the row says required/optional.
- [ ] **Step 1: Write the failing tests:**
  - `test_palette_lists_mise_tasks`: with FakeShell returning `fixture("mise-tasks.json")`, `Palette.tasks` names == the fixture's non-hidden names.
  - `test_palette_routes_interactive_to_terminal`: `mode("console") == :terminal`, `mode("test:rails") == :stream`.
  - `test_palette_unbalanced_quote`: `POST /w/wt-01/palette` with `task=test:rails`, `args=-n "foo` → 422, body contains `Unmatched quote`.
  - `test_palette_required_args`: `task=wt`, `args=` → 422 `arguments required`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement**; port `newterm.sh` / `claude-newterm.sh`. **Step 4: Run** — PASS; `bash -n .scripts/newterm.sh .scripts/claude-newterm.sh`.
- [ ] **Step 5: Commit** `git commit -m "dashboard: task palette; newterm.sh launcher from feature/tui"`.

### Task 9: Claude status hook v2

**Files:**
- Modify: `.container-config/claude-status-hook.sh` (← `feature/tui:.tui/docs/design/hook/claude-status-hook.sh`), `.container-config/entrypoint-claude.sh` (registration block ← `feature/tui:.tui/docs/design/hook/register-status-hook.sh`, replacing the block guarded by `grep -q claude-status-hook`)
- Create: `.dashboard/test/hook/test-claude-status-hook.sh` (← `feature/tui:.tui/docs/design/hook/test-claude-status-hook.sh`, default hook path `../../../.container-config/claude-status-hook.sh`, payloads from `../fixtures/hook-payloads`)
- Modify: `.dashboard/Rakefile` (`hook` task; `default: %i[test hook]`)

- [ ] **Step 1: Copy the test and fixtures first; run** `sh .dashboard/test/hook/test-claude-status-hook.sh`. Expected: FAIL lines (old v1 hook).
- [ ] **Step 2: Install the v2 hook and registration block.** Update the hook's header comment: it feeds the web dashboard, which reads the files from disk (no more nginx `/status/`). Keep the debug capture.
- [ ] **Step 3: Run** `mise run dashboard:test`. Expected: all `ok` lines, minitest PASS.
- [ ] **Step 4: Commit** `git commit -m "claude status hook v2: phases, tool and last message"`.

### Task 10: Unit, mise tasks, session environment plumbing

**Files:**
- Create: `.container-config/systemd/dashboard.service`
- Modify: `.scripts/quadlet.sh`, `.scripts/podman-wt.sh` (`start_proxy`, status lines), `.scripts/lib.sh` (`push_session_env`, `ensure_unit_env`), `.scripts/units-env.sh` (agent socket), `.scripts/podman-destroy.sh`, `.mise/config.toml` (tasks `dashboard`, `dashboard:stop`, `dashboard:autostart`)

**Interfaces:**
- Produces:
  - Unit template: `[Unit] Description=wt dashboard for @@P@@`; `[Service] WorkingDirectory=@@ROOT@@`, `ExecStart=@@MISE@@ run dashboard:serve`, `Restart=on-failure`; `[Install] WantedBy=default.target`. `render()` gains `@@MISE@@` = `command -v mise` at install time.
  - `quadlet.sh`: `SYSTEMD_DEST="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"`; `install` renders `.container-config/systemd/*` there with the same marker line; before rendering, any marker-bearing file in `DEST` or `SYSTEMD_DEST` without a template is stopped (`systemctl --user stop` of its service name — `<x>.container` → `<x>.service`) and removed, printing `removed orphan <file>`; `stale_units` also walks the systemd templates and reports orphans as `<file>\tno template (remove with units:install)`; `uninstall` runs `systemctl --user disable --now "${PROJECT_PREFIX}-dashboard.service"` before removing files; `PROXY_UNITS=(traefik dozzle)`; `proxy:up` additionally starts the dashboard, `proxy:down` and `proxy:restart` never touch it; `proxy:status` lists it and prints `dashboard  http://wt.localhost:${WT_DASHBOARD_PORT}`; `doctor` warns when `systemctl --user show-environment` has neither `DISPLAY` nor `WAYLAND_DISPLAY` ("terminal actions from the dashboard need a display; run mise run dashboard from a desktop session").
  - `lib.sh` `push_session_env`: for each of `SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP KITTY_LISTEN_ON` that is set and non-empty, `systemctl --user set-environment NAME=value`; never unsets.
  - `ensure_unit_env`: when `$SSH_AUTH_SOCK` is not a live socket but the file's `SSH_AGENT_SOCK` is one, that is not stale. `units-env.sh`: when `$SSH_AGENT_SOCK` is `/dev/null` or not a socket and the previous `$OUT` names a live socket, write the previous value (and skip the warning).
  - `start_proxy`: `push_session_env`, then start `traefik dozzle dashboard`.
  - `[tasks.dashboard]` (`usage = 'arg "[browser]"'`): `push_session_env`; `systemctl --user start "$PROJECT_PREFIX-dashboard.service"`; poll `curl -fsS -H "Host: wt.localhost:$WT_DASHBOARD_PORT" "http://127.0.0.1:$WT_DASHBOARD_PORT/healthz"` up to 15 s (on timeout: `error: dashboard did not answer; journalctl --user -u <unit> -n 30`); print the URL; open it with the browser argument else `xdg-open` (as `wt:open`).
  - `[tasks."dashboard:stop"]`: `systemctl --user stop` the unit. `[tasks."dashboard:autostart"]` (`usage = 'arg "[state]" help="on or off; omit to print"'`): `on` → `enable`, `off` → `disable`, none → print `is-enabled`; anything else → usage error.
  - `podman-destroy.sh`: `systemctl --user disable --now` the dashboard before removing units.
- [ ] **Step 1: Implement** the template and the script changes.
- [ ] **Step 2: Verify locally what can run here:** `bash -n` on every changed script; `PROJECT_PREFIX=t XDG_CONFIG_HOME=$(mktemp -d) …` is not enough for `install` (it needs podman), so instead run a throwaway check of `render` on the unit template: `sed`-equivalent output contains `ExecStart=/…/mise run dashboard:serve` and no `@@`.
- [ ] **Step 3: Commit** `git commit -m "dashboard: systemd unit, optional autostart, session environment"`.

### Task 11: Remove the old page; verify; docs

**Files:**
- Delete: `.container-config/quadlet/home.container`, `.container-config/proxy/index.html`, `.container-config/proxy/home-nginx.conf` (and `proxy/` if empty)
- Modify: `.scripts/quadlet.sh` (`cmd_verify`, `cmd_proxy_pull`), `.scripts/podman-wt.sh` (status lines), `.scripts/remove-worktree.sh`, `.container-config/entrypoint-claude.sh` (comments), `README.md`, `AGENTS.md`

- [ ] **Step 1: Delete the files**; drop `docker.io/library/nginx:alpine` from `proxy:pull`.
- [ ] **Step 2: `cmd_verify`:** remove the `wt-home`/`wt-api` router checks, the `wt.localhost` host check and the `/api` content-type check (keep `logs.localhost` and `wt-logs`); add `ok "dashboard answers"` via the `/healthz` curl above, and run `.scripts/dashboard-isolation-check.sh` (exit 1 → `bad`, 2 → `warn`).
- [ ] **Step 3: Update every mention** found by `grep -rn 'wt\.localhost\|-home\b\|home\.container\|index\.html\|home-nginx' .scripts .mise .container-config README.md AGENTS.md`: status lines print `dashboard  http://wt.localhost:<port>`; README gets the dashboard tasks; AGENTS.md: Layout (`.dashboard/`, `.container-config/systemd/`), Proxy (traefik + dozzle; the dashboard is not part of it), Worktree stack/hook, mise tasks, and a new "Dashboard (.dashboard/)" section: architecture, security model (loopback, Host/Origin/token, no login by user decision, isolation check), GitHub refresh rules, scopes, autostart, how to run and test, "change state only through mise tasks".
- [ ] **Step 4: Run** `mise run dashboard:test` and `bash -n` on changed scripts. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Remove the nginx wt.localhost page; document the dashboard"`.

### Task 12: Browser smoke here, host verification there

- [ ] **Step 1: Browser smoke (this sandbox).** Write a throwaway `/tmp/serve-fixtures.rb` that builds `App.build` with a hub fed the fixture raw and a runner whose spawner echoes its argv, serve it with Falcon on 127.0.0.1:7799, and drive it with the `browser` tool: the page lists 16 worktrees; clicking a row navigates and the detail shows the stack; `up` streams a job into the panel; the palette opens with `:` and filters; an injected `[:notify]` produces a Notification call (stub `window.Notification`); light and dark both readable. Screenshot each. Delete the script.
- [ ] **Step 2: Host wizard.** Use the `wizard` skill to generate `/tmp/dashboard-host-check.sh` for the user, walking through: `mise run units:install` (orphaned `home` removed), `mise run dashboard` (page opens), `mise run verify` (isolation all blocked), stack down → every worktree listed; `up` from the page → services go ◐ then ●; `test:rails` streams; `nvim` opens a terminal window; `GIT_TRACE=1 gh stack view --json` in a stacked worktree shows no `fetch`/`ls-remote` (if it does, add `protocol.allow=never` to the background `GitSafety` env and re-test); an `AskUserQuestion` in a claude session raises a notification; `dashboard:autostart on`, re-login, page is up; `dashboard:autostart off`; `proxy:down` leaves the dashboard up.
- [ ] **Step 3:** Report results; fix anything that fails in the owning task's files with a regression test, then re-run `mise run dashboard:test`.
