# Maximum length for a sanitized worktree name. Keeps DNS labels well under
# the 63-char limit and produces readable browser URLs like
# `worktree-name.localhost` and `s3.worktree-name.localhost`.
WORKTREE_NAME_MAX_LEN=40

# Sanitize a branch/worktree name into a safe directory + hostname slug:
# lowercase, non-alphanumerics → '-', collapse runs of '-', strip leading/
# trailing '-', cap at $WORKTREE_NAME_MAX_LEN chars, then strip any trailing
# '-' that the cap may have left behind.
sanitize_worktree_name() {
  echo "$1" \
    | sed 's/[^a-zA-Z0-9]/-/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-"$WORKTREE_NAME_MAX_LEN" \
    | sed 's/-$//'
}

# POSIX sh. Functions that need scratch variables use a ( ) body instead of
# `local`, which is not POSIX: the subshell keeps them out of the caller.

# Returns the absolute path to the orchestration root.
# A sourced sh file cannot learn its own path, so this goes by the sourcing
# script's ($0). Every caller is a script in .scripts/, executed rather than
# sourced, so that is this file's directory too, regardless of $PWD.
find_project_root() {
  (cd "$(dirname "$0")/.." && pwd)
}

# Returns the absolute path to a directory with app git context.
# Walks up from $PWD (stopping at the project root), then falls back to
# scanning the project root's subdirectories.
# Prefers the base worktree (.git directory) over linked worktrees (.git file).
find_git_dir() (
  root=$(find_project_root)

  # Walk up from $PWD looking for app git context (skip the project root
  # itself, which has its own unrelated git repo)
  dir="$PWD"
  while [ "$dir" != "$root" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.git" ] || [ -d "$dir/.git" ]; then
      echo "$dir"
      return
    fi
    dir="$(dirname "$dir")"
  done

  # Search project root subdirectories — prefer the base worktree
  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -d "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -f "${d}.git" ]; then
      echo "${d%/}"
      return
    fi
  done

  echo "No app git repository found in $root" >&2
  return 1
)

# Returns the directory name of the base worktree (the one with a .git directory).
find_base_worktree_name() (
  root=$(find_project_root)

  for d in "$root"/*/; do
    [ -d "$d" ] || continue
    if [ -d "${d}.git" ]; then
      basename "${d%/}"
      return
    fi
  done

  echo "No base worktree found in $root" >&2
  return 1
)

# Regenerate .unit-env/<worktree>.env if it is missing or older than anything it
# is derived from. That file is a cache: NODE_VERSION, RUBY_VERSION, the
# Playwright tag and the image tags built from them are all read out of it
# rather than recomputed, so until now a `.nvmrc` bump on a branch left `build`
# building the old node tag and `up` starting it, with nothing saying why.
# mtime, not content: a checkout that changes the file also touches it, and a
# needless regeneration costs one mise eval.
# Takes no worktree argument on purpose: units-env.sh regenerates whichever
# worktree CURRENT_WORKTREE_NAME names, so a name passed in here could only
# disagree with the file it actually rewrites.
ensure_unit_env() (
  wt="${CURRENT_WORKTREE_NAME:?not set -- run from inside a worktree}"
  stale=""
  root="$(find_project_root)"
  out="$root/.unit-env/$wt.env"

  if [ ! -f "$out" ]; then
    stale="no env file yet"
  else
    for src in "$root/$wt/.nvmrc" "$root/$wt/.ruby-version" \
               "$root/$wt/Gemfile.lock" "$root/$wt/mise.local.toml" \
               "$root/$wt/config/database.yml" "$root/mise.local.toml" \
               "$root/.mise/local.toml.template" "$root/.scripts/units-env.sh"; do
      # find -newer, not test -nt: -nt is not POSIX.
      [ -f "$src" ] && [ -n "$(find "$src" -prune -newer "$out")" ] || continue
      stale="${src#"$root"/} changed"
      break
    done
  fi
  # The agent socket is the one baked value with no file to date-stamp: its path
  # changes whenever the agent restarts, and the stale one is then a bind source
  # that podman refuses outright. So it is compared against the live agent
  # rather than an mtime, and both nvim@ and podman-claude.sh can trust the
  # value in the file instead of each re-deciding what to do about it.
  #
  # No live agent here (a dashboard action, a non-desktop shell) while the file
  # still names a live one is not stale: units-env.sh would keep that value
  # anyway, and regenerating on every such call would only churn the file.
  if [ -z "$stale" ]; then
    live="${SSH_AUTH_SOCK:-}"
    if [ -S "$live" ]; then
      grep -qxF "SSH_AGENT_SOCK=$live" "$out" || stale="ssh agent socket changed"
    else
      have="$(sed -n 's/^SSH_AGENT_SOCK=//p' "$out")"
      [ "$have" = /dev/null ] || [ -S "$have" ] || stale="ssh agent socket changed"
    fi
  fi
  [ -n "$stale" ] || return 0

  printf '%s; regenerating %s...\n' "$stale" "${out#"$root"/}" >&2
  "$root/.scripts/units-env.sh" >&2
)

# Copy the calling shell's desktop session into the systemd user manager, so
# the dashboard -- a service, with whatever environment the manager had when it
# started, possibly at boot -- hands its children (terminals, `up` regenerating
# .unit-env) a current display and agent socket. It reads them back from the
# manager at every child start. Only set values are pushed and nothing is ever
# unset: a shell without a display must not take one away from the dashboard.
push_session_env() (
  set --
  for name in SSH_AUTH_SOCK DISPLAY WAYLAND_DISPLAY XDG_CURRENT_DESKTOP KITTY_LISTEN_ON; do
    eval "val=\${$name:-}"
    [ -n "$val" ] && set -- "$@" "$name=$val"
  done
  [ "$#" -eq 0 ] || systemctl --user set-environment "$@"
)

# Open URL $1 in a browser: $2 when given (a binary name), else xdg-open.
# Detached, never exec'd: when no browser is running yet, xdg-open (or the
# binary) runs the browser itself in the foreground, which pinned the terminal
# until the browser closed and let ^C there kill it. setsid -f gives it its own
# session with no controlling terminal; with all three streams on /dev/null,
# nothing keeps mise waiting.
open_url() (
  if [ -n "${2:-}" ]; then
    command -v "$2" >/dev/null 2>&1 || { echo "error: '$2' not found in PATH" >&2; exit 1; }
    set -- "$2" "$1"
  else
    command -v xdg-open >/dev/null 2>&1 \
      || { echo "error: xdg-open not found; pass a browser binary name, e.g. firefox" >&2; exit 1; }
    set -- xdg-open "$1"
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$@" </dev/null >/dev/null 2>&1
  else
    nohup "$@" </dev/null >/dev/null 2>&1 &
  fi
)
