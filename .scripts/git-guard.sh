#!/bin/sh
# Host-side tamper check for the app repo's git state, plus backups of its hooks.
#
# The claude and nvim containers mount master/.git writable: commits, gh-stack
# (which writes upstream config) and hook editing all happen in there. So the
# places where a write turns into code your HOST git runs -- .git/hooks,
# .git/config (core.fsmonitor, core.hooksPath, filters, include.path, ...) and
# each worktree's .git pointer file -- cannot be made read-only. This detects
# a change after the fact instead: `up` and doctor run `check`.
#
# Hooks: every non-.sample file in master/.git/hooks must match its tracked
# copy in .container-config/git-hooks/. That covers the hand-written ones
# (pre-push is the push data-loss guard), which git never tracks and a re-clone
# would lose, and the lefthook launchers, so a launcher rewrite shows up too --
# review it, then back it up.
#
#   check            silent when all is well; otherwise lists what to review, exits 1
#   backup [hook…]   copy installed hooks (default: all) over their backups; commit after
#   restore          install the backups; a hook that differs is kept unless FORCE=1
set -eu

. "$(dirname "$0")/lib.sh"
ROOT="$(find_project_root)"
SRC="$ROOT/.container-config/git-hooks"
COMMON="$ROOT/$(find_base_worktree_name)/.git"
DEST="$COMMON/hooks"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
rel() { printf '%s' "${1#"$ROOT"/}"; }

# Keys git, gh and gh-stack write in normal use. Anything else is flagged for a
# look; widen this list when a legitimate tool adds one. Names only: values are
# never printed, since remote URLs can carry credentials.
CONFIG_ALLOWED='^(core\.(repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode|symlinks)|branch\..+\.(remote|merge|rebase|pushremote|description)|remote\..+\.(url|pushurl|fetch|tagopt|prune|gh-resolved)|remote\.pushdefault|rerere\.(enabled|autoupdate))$'

installed() {
  for f in "$DEST"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.sample) continue ;; esac
    basename "$f"
  done
  return 0
}

backed_up() {
  for f in "$SRC"/*; do
    [ -f "$f" ] && basename "$f"
  done
  return 0
}

# Same bytes and same executable bit: a hook that lost +x is silently skipped
# by git, which is as good as missing.
same() {
  cmp -s "$SRC/$1" "$DEST/$1" || return 1
  [ -x "$SRC/$1" ] && [ -x "$DEST/$1" ] && return 0
  [ ! -x "$SRC/$1" ] && [ ! -x "$DEST/$1" ]
}

check_hooks() {
  for h in $(installed); do
    if [ ! -e "$SRC/$h" ]; then
      printf 'git hook %s has no backup. Read it; if it is yours: mise run hooks:backup %s, then commit\n' \
        "$(rel "$DEST/$h")" "$h"
      bad=1
    elif ! same "$h"; then
      printf 'git hook %s differs from its backup.\n' "$(rel "$DEST/$h")"
      printf '  Compare:        diff %s %s\n' "$(rel "$SRC/$h")" "$(rel "$DEST/$h")"
      printf '  Keep installed: mise run hooks:backup %s, then commit\n' "$h"
      printf '  Keep backup:    FORCE=1 mise run hooks:restore\n'
      bad=1
    fi
  done
  for h in $(backed_up); do
    [ -e "$DEST/$h" ] && continue
    printf 'git hook %s is backed up but not installed.\n' "$h"
    printf '  Reinstall: mise run hooks:restore   Retire it: git rm %s\n' "$(rel "$SRC/$h")"
    bad=1
  done
}

check_config() {
  names="$(git config --file "$COMMON/config" --name-only --list 2>/dev/null)" || {
    printf '%s does not parse: %s\n' "$(rel "$COMMON/config")" \
      "$(git config --file "$COMMON/config" --name-only --list 2>&1 >/dev/null)"
    bad=1
    return 0
  }
  odd="$(printf '%s\n' "$names" | grep -Ev "$CONFIG_ALLOWED" | sort -u)" || true
  [ -n "$odd" ] || return 0
  printf '%s has settings outside the usual set -- some make host git run a program:\n' "$(rel "$COMMON/config")"
  printf '%s\n' "$odd" | sed 's/^/  /'
  printf '  Inspect: git config --file %s --get-all <name>\n' "$(rel "$COMMON/config")"
  printf '  Legitimate? Add it to CONFIG_ALLOWED in .scripts/git-guard.sh\n'
  bad=1
}

# A linked worktree's .git is a one-line pointer into master/.git/worktrees/.
# Pointed anywhere else, host git in that worktree reads a config and hooks the
# writer chose.
check_pointers() {
  for d in "$ROOT"/*/; do
    [ -f "$d.git" ] || continue
    line="$(cat "$d.git")"
    case "$line" in
      "gitdir: $COMMON/worktrees/"*/*|*/.|*/..) ;;
      "gitdir: $COMMON/worktrees/"?*) continue ;;
    esac
    printf '%s does not point into %s: %s\n' "$(rel "$d.git")" "$(rel "$COMMON/worktrees")" "$line"
    bad=1
  done
}

cmd_check() {
  bad=0
  check_hooks
  check_config
  check_pointers
  return "$bad"
}

cmd_backup() {
  [ "$#" -gt 0 ] || set -- $(installed)
  [ "$#" -gt 0 ] || die "no hooks installed in $DEST"
  mkdir -p "$SRC"
  for h in "$@"; do
    case "$h" in */*|.*|'') die "not a hook name: $h" ;; esac
    [ -f "$DEST/$h" ] || die "no hook at $(rel "$DEST/$h")"
    if [ -f "$SRC/$h" ] && same "$h"; then
      printf '%s: backup already current\n' "$h"
      continue
    fi
    cp -p "$DEST/$h" "$SRC/$h"
    printf '%s: backed up to %s\n' "$h" "$(rel "$SRC/$h")"
  done
}

cmd_restore() {
  hooks="$(backed_up)"
  [ -n "$hooks" ] || die "nothing to restore: $(rel "$SRC") is empty"
  [ -d "$DEST" ] || die "no hooks directory at $DEST"
  status=0
  for h in $hooks; do
    if [ -e "$DEST/$h" ] && same "$h"; then
      printf '%s: already installed\n' "$h"
    elif [ -e "$DEST/$h" ] && [ -z "${FORCE:-}" ]; then
      printf '%s: installed copy differs from the backup; kept. FORCE=1 to overwrite.\n' "$h" >&2
      status=1
    else
      cp -p "$SRC/$h" "$DEST/$h"
      printf '%s: installed\n' "$h"
    fi
  done
  return "$status"
}

case "${1:-}" in
  check)   cmd_check ;;
  backup)  shift; cmd_backup "$@" ;;
  restore) cmd_restore ;;
  *) die "usage: $(basename "$0") {check|backup [hook…]|restore}" ;;
esac
