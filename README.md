# Ruby on Rails Podman-based Development Environment

Per-worktree Rails dev stacks as **rootless podman** containers, run as systemd user units
(Quadlet) behind one shared Traefik proxy. Each git worktree gets its own containers, its own
`<slug>.localhost` hostname and its own ports, so several branches run at once.

<img width="640" height="1035" alt="Oprah-You-Get-A-Car-Everybody-Gets-A-Container-meme" src="https://github.com/user-attachments/assets/3d314d90-b3c1-4e86-9775-cd042e0f21d0" />

> The last Docker-based version is tagged [`docker-final`](../../tree/docker-final).

## Requirements

- Podman >= 5 — on 4.x, Quadlet's `Notify=healthy` silently degrades and health-gated startup
  ordering breaks with no error
- A systemd user session (Linux). `loginctl enable-linger $USER` keeps the proxy up after logout
- The podman socket, which Traefik and Dozzle read: `systemctl --user enable --now podman.socket`
- `unqualified-search-registries = ["docker.io"]` in `registries.conf` — the Dockerfiles use short
  base image names (`debian:`, `node:`). Fedora/RHEL ship this; Debian/Ubuntu do not
- Mise
- Neovim (optional)
- Github CLI (optional, set GH_TOKEN securely in your environment)

`mise run doctor` checks all of the above, plus the proxy subnet and the privileged-port sysctl,
and prints the fix for anything it finds.

## Installation

`curl -fsSL https://raw.githubusercontent.com/jbigler/rails-dev-podman/main/.scripts/bootstrap.sh | sh -s -- [-p prefix] user/repo`

- `prefix` = optional name for project/folder (will use repo name by default)
- `user/repo` = Github user/repo (or a full URL to git repository)

Then, from inside the base worktree:

```sh
mise trust -y && mise install
mise run doctor         # podman >= 5, socket, :80 sysctl, linger
mise run allow-ports    # only if doctor flags it: lets rootless podman publish :80
mise run units:install  # render the Quadlet units; up refuses to start without them
mise run build          # writes the unit env file, then builds the images
mise run up
```

### Adopt an existing local checkout

If you already have the Rails app checked out (branches, uncommitted work, untracked files)
and don't want to re-clone, use `adopt.sh` instead of `bootstrap.sh`. It **moves** your
existing checkout in as the base worktree and leaves a **backward symlink** at the original
location, so your old path keeps working everywhere (editor, terminals, scripts).

```sh
# 1. Clone this wrapper next to your app
git clone https://github.com/jbigler/rails-dev-podman.git ~/code/rails-dev

# 2. From the wrapper root, adopt your existing checkout
cd ~/code/rails-dev
./.scripts/adopt.sh [-p <prefix>] [-b <base-name>] /path/to/your/existing/checkout
```

- `-p <prefix>` = podman volume/network/unit prefix (defaults to the checkout's folder name)
- `-b <base-name>` = base worktree directory name (defaults to the folder name; set to your
  default branch, e.g. `-b master`, to match the clone-time convention)
- `<path>` = path to an existing Rails checkout (must be a git repo root)

What it does:

- **Moves** `/path/to/your/existing/checkout` to `./<base-name>` (physically under the wrapper
  root — required, since mise resolves config by physical path and the base must inherit the
  wrapper's `.mise` config + tasks), then symlinks the original path to it so it keeps resolving.
  A *forward* symlink (leaving the app in place) does **not** work: the base would resolve outside
  the root and mise couldn't find `PROJECT_PREFIX`/tasks.
- Writes a git-ignored `mise.local.toml` at the wrapper root with `PROJECT_PREFIX`, volume names,
  `DEV_DB_NAME` (auto-detected from `config/database.yml`, falling back to `<prefix>_development`),
  and `NVIM_CONFIG_DIR`. An existing file is left alone — `PROJECT_PREFIX` names every container,
  volume, network and unit, so changing it would orphan everything already created.
- Renders the base worktree's `mise.local.toml` (ports/URLs) and locally git-ignores it in the app repo.
- Creates the shared podman volumes.

Then:

```sh
cd ~/code/rails-dev && mise trust && mise install
cd ~/code/rails-dev/<base-name> && mise trust && mise install
mise run doctor && mise run units:install && mise run build && mise run up
```

Notes:

- **Per-worktree files:** list untracked files (e.g. `.env.local`, `config/master.key`) in
  `.container-config/worktree-seed.txt`; each new worktree gets its own copy from the base worktree.
- **Neovim config:** by default nvim owns its config inside the container, in a shared
  `<prefix>_nvim_config` volume, so you configure it once from inside. Set `NVIM_CONFIG_DIR` in the
  workspace-root `mise.local.toml` to bind a host config read-only instead; point it at the real
  directory if `~/.config/nvim` is a symlink into a dotfiles repo, or the mount will dangle.
- **Editing units:** the Quadlet templates live in `.container-config/quadlet/`. After changing one,
  re-run `mise run units:install` — `up` refuses to start a unit that no longer matches its template.

## Mise tasks

Run from a worktree directory unless noted otherwise. Aliases shown in parentheses.

_Tip: Set a shell alias for "mise run" to "mr"._

### Lifecycle

- `mise run up` (`u`) — start this worktree's stack; systemd pulls in db, redis, rustfs, nvim and the proxy
- `mise run stop` (`s`) — stop this worktree's containers, keeping its volumes
- `mise run restart [service]` — recreate one service (default `rails`)
- `mise run down` — stop the containers **and** delete this worktree's db, rustfs and node_modules volumes (prompts, defaults to No)
- `mise run status` — unit and container state for this worktree, plus its URLs
- `mise run logs [service]` — follow a service's journal (default `rails`)
- `mise run build` (`b`) — build the rails, nvim, claude and playwright images
- `mise run pull` (`p`) — refresh the third-party images (postgres, redis, rustfs)
- `mise run clean` — remove containers, networks, volumes and image tags belonging to worktrees that no longer exist
- `mise run destroy` — remove every podman resource for this project, the rendered units and the project folder (type `destroy` to confirm)

### Host and unit management

- `mise run doctor` — check the rootless podman prerequisites and print fixes
- `mise run config:init` — create the workspace-root `mise.local.toml` if missing
- `mise run units:install` / `mise run units:uninstall` — render `.container-config/quadlet/` into `~/.config/containers/systemd/`, or remove it
- `mise run units:env` — regenerate the unit env file (run from the workspace root to do every worktree)
- `mise run allow-ports` — lower `net.ipv4.ip_unprivileged_port_start` to 80 so rootless podman can publish Traefik's `:80`
- `mise run verify` — check that Traefik actually discovered the proxy containers over the podman socket

### Proxy

- `mise run proxy:up` / `proxy:down` / `proxy:restart` — the shared Traefik, Dozzle and dashboard stack
- `mise run proxy:status` — its unit and container state, plus its URLs
- `mise run proxy:logs [service]` — follow a proxy service's journal (default traefik)
- `mise run proxy:pull` — pull updated traefik/dozzle/nginx images and recreate the containers

The dashboard is at `http://wt.localhost`; live logs for every project container at `http://logs.localhost`.

### Worktrees

- `mise run wt <branch | PR# | new-branch>` — create a new git worktree with its own mise.local.toml and ports
- `mise run wt:ls` — list all worktrees
- `mise run wt:open [browser]` — open the current worktree URL (`xdg-open` by default)
- `mise run wt:rm <branch | dir-name>` — fully remove a worktree: its units, containers, volumes and network, its git registration, ports.registry entry, container home and folder (refuses on the base worktree)
- `mise run wt:share` / `wt:unshare` — expose this one worktree (app + S3) over the tailnet for phone testing

### Development

- `mise run rails` — open a zsh shell in this worktree's Rails container
- `mise run console` (`c`) — Rails console
- `mise run exec <cmd>` — run a command in the rails container, or in a transient one when the stack is down
- `mise run nvim` (`v`) — connect to the in-container Neovim via `--remote-ui`
- `mise run claude` (`ai`) — run Claude Code in the `claude` container (`CLAUDE_NEW_TERM=1` or `claude:newterm` opens a new terminal tab)
- `mise run claude:rebuild` — rebuild the Claude image with the latest Claude Code
- `mise run claude:template:promote` / `claude:template:apply` — sync the Claude config set between a worktree home and the template
- `mise run log:trim` — truncate any worktree log over 100 MB

### Tests / CI

- `mise run test` (`t`) — Rails unit tests, then the JavaScript tests
- `mise run test:rails [args]` (`tr`) — `bin/rails test`
- `mise run test:rails_watcher [args]` (`trw`) — Retest: reruns the matching test on every save
- `mise run test:rails_system [args]` (`trs`) — `bin/rails test:system` (brings playwright up first)
- `mise run test:javascript [args]` (`tj`) — Vitest, once
- `mise run test:javascript_watcher [args]` (`tjw`) — Vitest in watch mode
- `mise run ci` — full CI lint + test pass

System tests drive a Chromium running in the `playwright` container. Watch them at
`http://vnc.<worktree>.localhost`.

### Database / RustFS snapshots

- `mise run db:dump` — dump dev DB and RustFS data into `.container-config/db-dumps/` for fast container restarts
- `mise run db:dump:clear` — remove dump files so the next start does a full `db:prepare`

## Host-side Rails DB commands

You can run `bin/rails db:migrate`, `bin/rails console`, `bin/rails test`, `psql`, etc. **directly on the host** (not in a container) and have them hit this worktree's containerized Postgres — while the app server stays containerized and browser-reachable.

How it works: each worktree's `db` container publishes Postgres on a per-worktree host port (`127.0.0.1:${DB_PORT}` where `DB_PORT = 55432 + WORKTREE_ID`), and `mise.local.toml` sets host-shell `PGHOST=127.0.0.1`, `PGPORT=${DB_PORT}`, `PGUSER`, `PGPASSWORD`. These `PG*` vars are host-only — they never enter the container (the `rails` service reads `PGHOST=db` from `.container-config/.env` and goes over the container network), so the container keeps talking to `db` directly. Rails picks development vs test automatically from `RAILS_ENV` (both databases live in the same container Postgres).

Requirements / notes:

- **A host bundle**: host-side `bin/rails` needs the gems installed for your host Ruby (`bundle install` on the host). The `pg` gem needs libpq.
- Per-worktree ports (55432, 55433, …) let multiple worktrees' databases run concurrently without collisions.
- After migrating, keep the test schema in sync (`bin/rails db:test:prepare`, or `RAILS_ENV=test bin/rails db:migrate`).
