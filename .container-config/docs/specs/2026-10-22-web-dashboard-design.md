# Web dashboard (wt.localhost:<port>) — design

Branch: `feature/web-dashboard` (off `main`). Status: draft for approval.

## Intent

One browser page for the whole workspace: every git worktree, whether or not its stack runs, with
its services, PR and gh stack, and what its Claude session is doing; and the buttons to act on it
without typing mise tasks. It replaces two things:

- the current wt.localhost page (nginx in the `<prefix>-home` container), which only knows the
  worktrees that have Traefik routes, i.e. the running ones, and can do nothing but link;
- the terminal UI on `feature/tui`, which is abandoned. Its data logic is ported here; its terminal
  code is not.

## Goals

- List **every** worktree (from `git worktree list`), running or stopped, base worktree included.
- Show per worktree: branch, ahead/behind, uncommitted count, the services' states, PR (number,
  title, review, checks), gh stack (when HEAD's branch is in one), Claude session state with its last
  message, the app/email/lookbook/routes/vnc/s3-console links.
- Run actions from the page, with their output streamed into it.
- Open a host terminal for everything that needs one.
- A task palette with every mise task.
- Browser notifications when a Claude session needs permission or asks a question.
- Workspace-level: a stale-units warning with an install button, a "need input" count.

## Non-goals

- Keyboard-driven menus like the TUI (mouse first; a few shortcuts at the builder's discretion).
- Any terminal inside the browser (xterm.js or similar).
- Agent chat (ACP, `agent@`, `acp-bridge` stay on `feature/tui`).
- CPU/memory stats. Log viewing beyond linking to Dozzle (logs.localhost stays).
- Remote/tailnet access to the dashboard. `wt:share` keeps sharing one worktree's app only.

## Anti-goals (failure even if it works)

- **Any container can trigger an action.** rails@ and playwright@ sit on the proxy network, and the
  playwright Chromium (which the agent drives over CDP) reaches `*.localhost` through Traefik. An
  action endpoint they can reach lets agent-written code run `fw:allow`, `exec`, `down` or `wt:rm` on
  the host — a full escape from the container and its firewall.
- **Re-implementing what a mise task or `.scripts/*.sh` owns.** The dashboard reads state directly
  but changes it only through mise tasks, `gh`, `git` and `newterm.sh` (the same rule the TUI had). A
  missing action becomes a mise task first.
- A slow or failing source (gh offline, podman socket down) breaking the page. It marks its cells
  unknown and the rest keeps working.

## Decided by the user

| Topic | Decision |
| --- | --- |
| TUI | The web dashboard replaces it. Port the parsers from `feature/tui`; that branch is not merged. |
| Language | Ruby (4.0.7, pinned through mise like `.tui` was). |
| Server | **Roda + Falcon.** |
| Front end | **Hotwire: Turbo + Stimulus**, server-rendered, no build step. |
| Terminal actions | The backend runs `newterm.sh` to open a host terminal. Nothing interactive in the browser. |
| Old wt.localhost page | **Replaced and removed**: the home container, its nginx config and index.html go away. |
| Login | **None.** Loopback plus Host/Origin/token checks; the host is single-user. |
| Start at login | **Optional, off by default**, switchable from the page and from a mise task. |
| First version also has | streamed output for actions and tests; the task palette; browser notifications. |

## Architecture

```
host browser ──http://wt.localhost:<port>──▶ dashboard (host process, 127.0.0.1:<port>)
                                               ├─ reads: git, systemctl --user, podman, gh,
                                               │         .unit-env/<W>.env, .container-config/status/*.json,
                                               │         quadlet.sh check-stale
                                               └─ acts:  mise run …, gh stack …, newterm.sh -- …
containers (rails, playwright, claude…) ──✗──▶ 127.0.0.1:<port>   (loopback only, not via Traefik)
```

- **A host process, not a container.** It needs `systemctl --user`, podman, gh (the user's auth),
  git, mise and the user's display for `newterm.sh`. It runs as a plain systemd user unit,
  `<prefix>-dashboard.service`.
- **Served directly, not through Traefik.** Bound to `127.0.0.1:${WT_DASHBOARD_PORT}`. Browsers resolve
  `*.localhost` to loopback, so the URL is `http://wt.localhost:<port>`. Traefik keeps :80. Nothing in
  any container can reach this port (see Security), which is what makes actions safe to offer.
- **One Falcon process.** All state (sources, running actions, subscribers) is in memory, so Falcon
  must not fork workers (`--count 1` or the equivalent). Async fibers run the sources, the action
  subprocesses and the SSE streams.
- **Live updates: one SSE stream per page** (`<turbo-stream-source src="/events">`). The server
  holds the current model; when a source changes something, it re-renders only the affected
  fragments (a list row, the detail pane, the header) and broadcasts them as Turbo Stream
  `replace` actions. No client polling.
- **Front end:** ERB templates through Roda's `render` plugin. Turbo and Stimulus are vendored ES
  module files served from the app, loaded through an import map. Stimulus controllers cover: menus
  and confirm dialogs, the palette, the action-output panel, notifications, copy-to-clipboard.
- **CSS:** hand-written, no UI kit. The Flexoki palette from the TUI's `theme.rb` as CSS custom
  properties, light and dark following `prefers-color-scheme`.

### Files

- `.dashboard/` — the app, laid out like `.tui/` was: `Gemfile` (+ lock), gems vendored into
  `.dashboard/vendor/bundle` (git-ignored), `config.ru`, `lib/`, `views/`, `public/` (CSS, vendored
  Turbo/Stimulus, controllers), `test/` (fixtures carried over from `feature/tui:.tui/test/fixtures/`),
  and the root `.gitignore`, an allowlist, gets `!/.dashboard/`. This document and its plan live in
  `.container-config/docs/{specs,plans}/` with the others.
- `.container-config/systemd/dashboard.service` — the unit template (see Unit and tasks).
- `.scripts/newterm.sh` — ported from `feature/tui` (commit `cd708ac`), with `claude-newterm.sh`
  becoming its thin wrapper as on that branch.

## Data sources

Port these from `feature/tui` — the rules, the parsers and their fixture tests. They are UI-agnostic
(`.tui/lib/wt/sources/`, `derive.rb`, `services.rb`, `agent_status.rb`, `workspace.rb`, `model.rb`,
and `shell.rb` minus its terminal handover). The spec is `git show feature/tui:.tui/docs/design/SPEC.md`;
section numbers below refer to it. Where it and this document differ, this document wins.

| Source | Command | Refresh | Spec |
| --- | --- | --- | --- |
| Worktrees | `git -C <base> worktree list --porcelain` | 5 s, and after `wt` / `wt:rm` | §3.2, §5.2 |
| Per-worktree values (ports, hosts) | read `.unit-env/<W>.env` (plain `KEY=VALUE`); no command | on mtime change | §3.2 |
| Git status | `git status --porcelain=v2 --branch` per worktree | 3 s | §5.2 |
| Units | one `systemctl --user show -p Id,ActiveState,SubState,Result …` | 3 s | §5.2 |
| Containers | one `podman ps -a --format json` | 3 s | §5.2 |
| Claude status | stat + read `.container-config/status/<W>.json` | 1 s, on mtime change | §6, §7 |
| Open PRs, with checks | `gh pr list --state open --json number,headRefName,baseRefName,state,isDraft,reviewDecision,title,url,statusCheckRollup` (repo-wide) | see GitHub refresh | §5.2, §5.3 |
| All PRs, without checks | `gh pr list --state all --limit 200 --json number,headRefName,state,title,url` (`--state` takes one value; this shows "merged" for a worktree whose branch is done) | on demand only, never on the timer | §5.2, §5.3 |
| gh stack | `gh stack view --json` in the worktree shown in the detail pane | see GitHub refresh | §3.5, §5.4 |
| Stale units | `quadlet.sh check-stale` | 60 s, after any action | — |

Every command runs with an argv array (never a shell string) and a timeout (5 s; 15 s for gh). A
failed or timed-out source keeps its last value and marks its cells unknown.

**GitHub refresh (no webhooks, no notifications API).** Webhooks need an endpoint reachable from
the internet, which this loopback-only server must not have. `gh webhook forward` is documented as
testing-only, is limited to one per repository and needs repo admin rights, and a relay such as
smee.io would show every PR event to a third party. The notifications and repo-events endpoints
can't stand in for polling either: notifications don't reliably report checks finishing, and repo
events have no check events and can lag by hours. So GitHub is polled, but only when someone is
looking:

- **On demand:** at startup; when a page connects or its tab regains focus (a Stimulus controller
  POSTs a refresh hint on `visibilitychange`); right after any action that touches GitHub finishes
  (stack push/up/down, new worktree, remove worktree). A restack runs in a terminal the dashboard
  can't watch, so its result shows on the next focus or timer tick. On demand means all three
  GitHub sources above.
- **Timer, only while at least one page holds the SSE stream:** open PRs and the shown worktree's
  stack every 60 s while any open PR has checks pending or the shown worktree has an open PR;
  otherwise every 5 minutes. With no page connected, no GitHub call is made at all.
- **One request for all open PRs:** checks come with the list (`statusCheckRollup`), so there is no
  per-PR `gh pr view`. The commit count shown for a PR is computed locally:
  `git rev-list --count origin/<baseRefName>..HEAD` in the worktree.
- Focus and connect hints are coalesced: one arriving while a refresh runs, or within 10 s of the
  last one, is dropped. A refresh after an action is never dropped; if one is already running, it
  runs again when that one ends.

**No container-written config turns into host code (my call).** The reads run every few seconds
with nobody watching, against files containers can write: claude and nvim mount `master/.git`
writable and the worktrees too. `git-guard.sh` lists how such a write becomes code host git runs
(`core.fsmonitor`, `core.hooksPath`, filters, `include.path`), and a `mise.local.toml` runs
commands through `exec()` templates. So:

- every git call, and every git call that gh or gh-stack makes, gets the overrides
  `core.fsmonitor=false`, `core.hooksPath=/dev/null` (as `-c` for git, and through
  `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` for gh's children, since command-line
  config wins over files and includes) plus `--no-optional-locks` on status;
- the dashboard never runs `mise env` in the background. Ports and hosts come from
  `.unit-env/<W>.env`, which lives outside every worktree and no container mounts. A worktree
  that has never been brought up has no such file: its host is still `<W>.localhost`, and its ports
  show as unknown.

Actions the user clicks run mise as they would from a terminal; the risk there is unchanged from
today.

Services shown: rails, postgres (db), redis, rustfs, playwright, with the state mapping in §5.2.
nvim is shown too, since `up` starts it again.

**Claude status hook v2.** Notifications and the permission/question states need the v2 status file
(§6). Install it as `feature/tui` designed it: `feature/tui:.tui/docs/design/hook/claude-status-hook.sh`
over `.container-config/claude-status-hook.sh`, and the `register-status-hook.sh` block in place of the
registration block in `entrypoint-claude.sh`; carry over its shell test. Keep `state`, `ts`, `rtk`
(the RTK savings chip moves to the new page). Agent state derivation: §7.

## Screen

One page. My call on layout, modelled on the TUI's:

- **Header:** repo name, "◆ N need input" (hidden at 0; also in the tab title), a stale-units banner
  with an "Install units" button when `check-stale` fails, links to logs.localhost and Traefik
  (:8080), buttons for "New worktree" and the palette, and a settings menu with the "Start at
  login" switch.
- **Worktree list** (left): every worktree, alphabetical, base last. Columns: name, branch, stack
  position `k/n`, PR number coloured by state, one services glyph, agent state. A row is a link;
  the selected worktree is in the URL (`/w/<name>`), so a reload or a bookmark keeps it.
- **Detail pane** (right): branch line; PR or stack block (stack drawn top-down like `gh stack view`,
  HEAD expanded, merged ones collapsed — §4.3, without the TUI's line-budget trimming, since the
  page scrolls); agent block with the tail of the last message; services with their state and a
  restart button each; the app links (disabled while rails is down); the action buttons.
- **Action panel** (bottom, collapsible): the running and recent actions, each with its streamed
  output, status, duration and a Cancel button while running.
- Narrow windows put the detail pane under the list.

## Actions

Every action runs with the worktree as cwd unless noted. Modes:

- **Stream:** spawn the command (own process group, stdin `/dev/null`, `NO_COLOR=1`), stream its
  output to the action panel, report exit status, refresh the affected sources when it ends. Cancel
  kills the process group.
- **Terminal:** `newterm.sh --title "<W>: <label>" --cwd <worktree> -- <argv>`; the page shows
  "opened <label>" or newterm.sh's `error:` line.
- **Link:** a plain link, no server round trip.

| Action | Mode | Command |
| --- | --- | --- |
| up / stop | Stream | `mise run up` / `mise run stop` |
| restart a service; restart all | Stream | `mise run restart <svc>`; `stop` then `up` |
| down | Confirm, Stream | `FORCE=1 mise run down` (the task refuses without a terminal otherwise) |
| logs of a service | Link | logs.localhost (Dozzle), deep-linked to the container if Dozzle allows |
| app, email, lookbook, routes, vnc, s3 console | Link | as the old page built them, but from `.unit-env` instead of Traefik routers |
| tests: all, rails, javascript, system | Stream | `mise run test`, `test:rails`, `test:javascript`, `test:rails_system` (+ vnc link) |
| test watchers | Terminal | `mise run test:rails_watcher`, `test:javascript_watcher` |
| nvim, console, rails shell | Terminal | `mise run nvim`, `console`, `rails` |
| claude | Terminal | running `<P>-<W>-claude` → `podman attach` it; else `mise run claude` |
| share / unshare | Stream | `mise run wt:share` / `wt:unshare` |
| stack push / up / down | Stream | `gh stack push` / `gh stack up` / `gh stack down` |
| restack | Terminal | `gh stack rebase` (may stop on conflicts) |
| open PR | Link | the PR URL from gh |
| copy branch name | Client | `navigator.clipboard` |
| new worktree | Prompt, Stream | `mise run wt <input>` (cwd root); select it when done |
| remove worktree | Confirm, Stream | `mise run wt:rm <W>` (cwd root); a separate "discard uncommitted changes" checkbox adds `FORCE=1`; never offered on the base worktree |
| install units | Stream | `mise run units:install` (cwd root) |
| start at login on / off | Stream | `mise run dashboard:autostart on` / `off` (cwd root) |
| palette | Stream or Terminal | `mise run <task> <args>`; see below |

**Palette.** `mise tasks --json` (cached 60 s), fuzzy filter by name, description shown. Arguments
from `usage`: a required `arg "<…>"` prompts before running, an optional one offers an optional
field; the input is split with Shellwords into argv. Tasks that need a terminal (they prompt or are
interactive: the claude family, console, nvim, rails, the watchers, destroy, clean, …) run in
Terminal mode from a list kept in the backend; the builder confirms each against the task. Everything
else streams; with stdin closed, a task that unexpectedly prompts fails instead of hanging.

**Concurrency:** one running action per worktree (its buttons show it as busy, and a second request
is refused); workspace-level actions (new worktree, install units) one at a time.

**Children outlive the dashboard (my call).** Every Stream and Terminal child is started through
`systemd-run --user --scope --collect`, so it gets its own cgroup. Restarting or stopping the
dashboard's unit (a crash, `dashboard:stop`, a reinstall) then doesn't kill the Claude or nvim
windows it opened, or a `wt` halfway through. A Stream action that survives a dashboard restart
keeps running, but its output is lost: the new process doesn't reattach. This also makes tasks
that act on the dashboard itself safe to start from the palette.

**Session environment (my call).** A systemd user service has no `SSH_AUTH_SOCK`, terminal or
`KITTY_LISTEN_ON`. That matters because an `up` started from the dashboard can regenerate
`.unit-env/<W>.env` (`ensure_unit_env`), and `SSH_AGENT_SOCK` would then fall back to `/dev/null`,
silently cutting the ssh agent off from nvim and claude. (`NVIM_BACKGROUND` is not in that file:
`mise run nvim` pushes it at attach time, and that runs in a terminal the dashboard opens, with
`KITTY_LISTEN_ON` passed on as below.)

Three changes:

- `mise run dashboard` and `start_proxy` push the calling shell's `SSH_AUTH_SOCK`, `DISPLAY`,
  `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP` and `KITTY_LISTEN_ON` into the user manager with
  `systemctl --user set-environment` before starting the unit.
- The dashboard reads those variables from the user manager (`systemctl --user show-environment`)
  each time it starts a child, and passes the current values on. A running service keeps the
  environment it started with, so without this a dashboard started at boot (autostart with linger)
  or before a re-login would hand out a missing or stale display and ssh-agent socket. Unset
  variables stay unset; a terminal launch that then fails shows newterm.sh's `error:` line.
- `units-env.sh` keeps the previous file's `SSH_AGENT_SOCK` when the current environment has no
  live agent socket and the previous value still is one, instead of falling back to `/dev/null`;
  `ensure_unit_env` (lib.sh) stops calling that case stale.

**Retention:** in memory, the last 20 actions, output capped per action; lost on restart.

## Security

- Listen on `127.0.0.1` only.
- Every request (GET and the SSE stream included) must carry a `Host` of `wt.localhost:<port>`,
  `localhost:<port>` or `127.0.0.1:<port>`; anything else gets 403. This stops DNS rebinding.
- Every state-changing request is a POST with the token issued at server start (embedded in the page
  as a meta tag, sent in a custom header) and an `Origin` matching an allowed host. This stops other
  pages in the user's browser.
- Commands are argv arrays; user input reaches them only as arguments.
- **Isolation is verified, not assumed.** AGENTS.md says containers cannot reach loopback-bound host
  ports; `mise run verify` gains a check that tries the dashboard port from a throwaway container on
  the proxy network (via `host.containers.internal` and the network gateway) and from a running
  playwright container (via `wt.localhost:<port>`), and fails if any connects.
- Other processes of the same user can still call it; they could already run mise.
- **No login (user's decision).** Host, Origin and the page token stop browsers, not other
  clients: anything that can open a TCP connection to the port can fetch the page and its token.
  The design accepts this on the premise that the host is single-user and containers can't reach
  the port.
- **Isolation comes first in the build.** Because isolation is the only barrier against
  non-browser clients in containers, the plan starts with the isolation check (a minimal listener
  on the chosen port plus the `verify` probes, run on this host's rootless network setup) before
  any UI work. If any probe connects, stop and bring it back to the user; the build does not go on.

## Unit and tasks

- `.container-config/systemd/dashboard.service`, rendered by `units:install` into
  `~/.config/systemd/user/<prefix>-dashboard.service` (Quadlet's dir only takes container units). It
  joins `install`, `uninstall` and `check-stale`. ExecStart runs `mise run dashboard:serve` from the
  workspace root (mise's absolute path baked in at render time), so Ruby and the env come from mise.
  `Restart=on-failure`.
- **Independent of the proxy.** It no longer goes through Traefik, so it has no dependency on it:
  `proxy:down` / `proxy:restart` leave it running, since it is the page you would bring things back
  up from. podman-wt.sh's `start_proxy` starts it alongside traefik and dozzle (in place of `home`);
  `proxy:up` does too. It stops only through `dashboard:stop`, `units:uninstall` or `destroy`.
- **Start at login: optional, off by default (user's decision).** The unit carries
  `[Install] WantedBy=default.target`, but `units:install` never enables it, so by default it starts
  on demand (`mise run dashboard`, `up`, `proxy:up`), like everything else here. Turning autostart on
  is `systemctl --user enable`; the user manager then starts it at login, or at boot with linger.
  - The state lives in systemd alone (the enable symlink), not in a settings file. Re-rendering the
    unit file on `units:install` keeps it; `units:uninstall` and `destroy` disable it first so no
    dangling symlink is left.
  - mise tasks `dashboard:autostart` (`on` / `off`, no argument prints the state) own the change.
  - **The page has the same toggle** (in the header's settings menu), showing
    `systemctl --user is-enabled` and running `dashboard:autostart on|off` as a Stream action.
  - With autostart and linger on, it starts before any login session: the page works, and terminal
    launches fail with newterm.sh's error until a session (or `mise run dashboard`) supplies a
    display; the per-child environment read above makes them work from then on without a restart.
- `newterm.sh` needs `DISPLAY` / `WAYLAND_DISPLAY` in the user manager's environment (pushed there
  as described under Actions). `doctor` warns when they are missing. From a service there is no
  parent terminal to open a tab in, so terminals open as new windows unless `newterm.sh` can target a
  running terminal another way (e.g. kitty remote control via the pushed `KITTY_LISTEN_ON`, tmux) —
  a limitation to note, not to fix.
- mise tasks:
  - `dashboard [browser]`: push the session environment, start the unit if it is not running, wait
    until it answers, print the URL and open it (the optional browser binary, else `xdg-open`, as
    `wt:open` does).
  - `dashboard:stop`, `dashboard:autostart [on|off]`.
  - `dashboard:serve`: foreground; what the unit runs; installs the vendored gems when needed.
  - `dashboard:test`.
- Port: `WT_DASHBOARD_PORT` in `.mise/config.toml`'s env, overridable in the workspace-root
  `mise.local.toml` (a second workspace needs a different one).
- **Orphaned units.** Removing `home.container` would leave the installed
  `<prefix>-home.container` running forever: `install` and `check-stale` only walk the templates.
  `install` must remove rendered files (identified by the marker line) that no longer have a
  template, and `check-stale` must report them.

## Removing the old page

Delete `.container-config/quadlet/home.container`, `.container-config/proxy/index.html` and
`home-nginx.conf` (and the `proxy/` dir if empty), the `wt-home` / `wt-api` routers, nginx from
`proxy:pull`, and the `wt-home` / `wt-api` / wt.localhost checks in `verify` (replaced by a check that
the dashboard answers). Update every mention: podman-wt.sh's status lines, quadlet.sh's proxy status,
the comments in `claude-status-hook.sh`, `entrypoint-claude.sh` and `remove-worktree.sh`, README and
AGENTS.md (Layout, Proxy, mise tasks; a new Dashboard section replacing what the TUI section would
have been).

## Testing and verification

- Minitest, as on `feature/tui`: sources on the captured fixtures (no podman, systemd, gh or network
  needed), agent-state derivation, the Host/Origin/token guard, the palette's argument handling and
  terminal-task routing, action lifecycle (stream, exit status, cancel, one-per-worktree), and the
  GitHub schedule on a fake clock (no calls with no page connected, 60 s vs 5 min, hint coalescing,
  action refreshes never dropped).
- The status hook's shell test against the captured payloads.
- On the host: `mise run verify` including the isolation check; then the page itself — every
  worktree listed with the stack down, `up`/`stop` reflected live, a test run streaming, a terminal
  action opening a window, a notification on an `AskUserQuestion`.

## Left to the builder

- Gem versions; Falcon flags for a single process bound to 127.0.0.1 over plain HTTP.
- Template and fragment structure, Stimulus controller split, CSS details.
- Exact output cap, how much ANSI to strip.
- Dozzle deep-link format.
- Any keyboard shortcuts.
