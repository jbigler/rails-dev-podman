#!/usr/bin/env bash
# Worktree picker: one fzf list of every worktree -- stack up or not, Claude
# state, local changes, last activity -- most recently active first. Type to
# filter; keys act on the selected row through the existing mise tasks, in that
# worktree's directory so its mise env loads. Long-running tools (claude, nvim,
# logs, console, a shell) open in their own terminal tab per worktree, and a
# second press focuses that tab instead of opening another (newterm.sh).
#
# fzf calls back into this script for the rows, the preview and the actions:
#   wt-pick.sh                 the picker
#   wt-pick.sh rows            one tab-separated line per worktree: slug, display
#   wt-pick.sh preview <slug>
#   wt-pick.sh act <action> <slug> [query]
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
source "$(dirname "$SELF")/lib.sh"
ROOT="$(find_project_root)"
P="${PROJECT_PREFIX:?run through mise: mise run wt:pick}"
STATUS_DIR="$ROOT/.container-config/status"
# Seconds between background row refreshes; 0 turns them off.
REFRESH="${WT_PICK_REFRESH:-5}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then COLOR=1; else COLOR="${WT_PICK_COLOR:-}"; fi
paint() { if [ -n "$COLOR" ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# "<dir>\t<branch>" for every worktree under the wrapper root, base included.
worktrees() {
  local base
  base="$ROOT/$(find_base_worktree_name)" || exit 1
  git -C "$base" worktree list --porcelain | awk -v root="$ROOT/" '
    /^worktree / { dir = substr($0, 10); branch = "" }
    /^branch /   { branch = substr($0, 8); sub("^refs/heads/", "", branch) }
    /^detached/  { branch = "(detached)" }
    /^$/ { if (index(dir, root) == 1) print dir "\t" branch; dir = "" }
    END  { if (dir != "" && index(dir, root) == 1) print dir "\t" branch }'
}

# "<changed files> <ahead> <behind> <last commit epoch>" for one worktree.
git_info() {
  local status ct
  status=$(git -C "$1" status --porcelain=v2 --branch 2>/dev/null \
    | awk '/^# branch.ab/ { a = substr($3, 2); b = substr($4, 2) }
           /^[^#]/        { n++ }
           END            { printf "%d %d %d", n, a, b }') || status="0 0 0"
  ct=$(git -C "$1" log -1 --format=%ct 2>/dev/null) || ct=0
  printf '%s %s\n' "$status" "${ct:-0}"
}

# Slugs of worktrees whose rails unit is active, one per line.
active_stacks() {
  local unit
  systemctl --user list-units "$P-rails@*.service" --state=active --plain --no-legend 2>/dev/null \
    | while read -r unit _; do
        unit="${unit#"$P-rails@"}"; printf '%s\n' "${unit%.service}"
      done
}

# Slugs of worktrees with a running claude container (podman-claude.sh names it
# <prefix>-<slug>-claude).
running_claudes() {
  local name
  podman ps --format '{{.Names}}' 2>/dev/null | while read -r name; do
    case "$name" in "$P"-*-claude) name="${name#"$P-"}"; printf '%s\n' "${name%-claude}" ;; esac
  done
}

# "<state> <epoch>" from the status hook's file, or nothing.
agent_status() {
  local f="$STATUS_DIR/$1.json" state ts
  [ -f "$f" ] || return 0
  state=$(sed -n 's/.*"state":"\([a-z]*\)".*/\1/p' "$f")
  ts=$(sed -n 's/.*"ts":"\([^"]*\)".*/\1/p' "$f")
  printf '%s %s\n' "${state:-?}" "$(date -d "$ts" +%s 2>/dev/null || echo 0)"
}

ago() {
  local s=$(( $(date +%s) - $1 ))
  if [ "$1" -le 0 ]; then printf '?'
  elif [ "$s" -lt 3600 ]; then printf '%dm' $(( s / 60 ))
  elif [ "$s" -lt 86400 ]; then printf '%dh' $(( s / 3600 ))
  else printf '%dd' $(( s / 86400 )); fi
}

cmd_rows() {
  local tmp list stacks claudes dir branch slug changed ahead behind ct state ts
  local width=4 activity stack agent changes
  tmp=$(mktemp -d)
  list=$(worktrees)
  # git status on a big app checkout is the slow part; do them all at once.
  while IFS=$'\t' read -r dir _; do
    slug="${dir##*/}"
    git_info "$dir" > "$tmp/$slug" &
    [ ${#slug} -gt "$width" ] && width=${#slug}
  done <<< "$list"
  stacks=$(active_stacks); claudes=$(running_claudes)
  wait

  while IFS=$'\t' read -r dir branch; do
    slug="${dir##*/}"
    read -r changed ahead behind ct < "$tmp/$slug"
    activity=$ct

    if grep -qxF "$slug" <<< "$stacks"; then stack=$(paint 32 '● up  ')
    else stack=$(paint 2 '○ down'); fi

    # Padded before painting: printf widths would count the escape codes.
    agent=$(paint 2 '·        ')
    if grep -qxF "$slug" <<< "$claudes"; then
      read -r state ts <<< "$(agent_status "$slug")" || true
      [ "${ts:-0}" -gt "$activity" ] && activity=$ts
      case "${state:-}" in
        working) agent=$(paint 32 '● working') ;;
        waiting) agent=$(paint 33 '◆ waiting') ;;
        *)       agent=$(paint 36 '◐ open   ') ;;
      esac
    fi

    changes=""
    [ "$changed" -gt 0 ] && changes+="✎$changed "
    [ "$ahead" -gt 0 ] && changes+="↑$ahead "
    [ "$behind" -gt 0 ] && changes+="↓$behind"
    # The slug already says which branch it is, except when the worktree has
    # since switched branches or the name was cut or hash-suffixed.
    [ "$(sanitize_worktree_name "$branch")" = "$slug" ] && branch=""

    # The leading epoch is only for the sort and is cut off below.
    printf '%s\t%s\t%-*s  %s  %s  %-12s %s  %s\n' "$activity" "$slug" "$width" "$slug" \
      "$stack" "$agent" "$changes" "$(paint 2 "$(printf '%4s' "$(ago "$activity")")")" "$(paint 2 "$branch")"
  done <<< "$list" | sort -t$'\t' -k1,1nr | cut -f2-
  rm -rf "$tmp"
}

cmd_preview() {
  local slug="$1" dir="$ROOT/$1" state ts
  [ -d "$dir" ] || { echo "gone: $slug"; return; }
  printf '%s  %s\n' "$(paint 1 "$slug")" "$(git -C "$dir" branch --show-current 2>/dev/null)"
  printf 'http://%s.localhost\n\n' "$slug"

  read -r state ts <<< "$(agent_status "$slug")" || true
  if grep -qxF "$slug" <<< "$(running_claudes)"; then
    printf 'claude   %s, %s ago\n' "${state:-running}" "$(ago "${ts:-0}")"
  else
    printf 'claude   not running\n'
  fi
  systemctl --user list-units "$P-*@$slug.service" --all --plain --no-legend 2>/dev/null \
    | awk -v p="$P-" '{ u = $1; sub("^" p, "", u); sub("@.*", "", u); printf "%-8s %s/%s\n", u, $3, $4 }'

  printf '\n'; git -C "$dir" -c color.status=always status -sb 2>/dev/null | head -20
  printf '\n'; git -C "$dir" log --color=always --format='%C(yellow)%h%C(reset) %s %C(dim)%cr%C(reset)' -8 2>/dev/null

  # Last: gh is the slow one, and fzf shows the lines above while it runs.
  if command -v gh >/dev/null 2>&1; then
    printf '\n'
    (cd "$dir" && timeout 5 gh pr view --json number,title,state,isDraft,reviewDecision \
      --template '#{{.number}} {{.title}}{{"\n"}}{{.state}}{{if .isDraft}} draft{{end}} {{.reviewDecision}}{{"\n"}}' \
      2>/dev/null) || printf 'no PR\n'
  fi
}

# Wait for a key after a foreground action fails, or its error is wiped by fzf
# redrawing straight away.
run_here() {
  "$@" && return 0
  printf '\n%s ' "$(paint 31 'failed -- press enter')"; read -r _ </dev/tty || true
}

cmd_act() {
  local action="$1" slug="$2" query="${3:-}" dir="$ROOT/$2"
  local tab="$ROOT/.scripts/newterm.sh"
  [ "$action" = new ] || [ -d "$dir" ] || die "no worktree $slug"
  case "$action" in
    # The tab title matches claude-newterm.sh, so claude:newterm and the picker
    # find each other's tab. CLAUDE_NEW_TERM is dropped or the new tab would
    # open yet another one.
    claude)  "$tab" --cwd "$dir" --title "claude:$slug" -- env -u CLAUDE_NEW_TERM mise run claude ;;
    nvim)    "$tab" --cwd "$dir" --title "nvim:$slug" -- mise run nvim ;;
    logs)    "$tab" --cwd "$dir" --title "logs:$slug" -- mise run logs ;;
    console) "$tab" --cwd "$dir" --title "console:$slug" -- mise run console ;;
    shell)   "$tab" --cwd "$dir" --title "sh:$slug" -- "${SHELL:-bash}" ;;
    up)      (cd "$dir" && run_here mise run up) ;;
    stop)    (cd "$dir" && run_here mise run stop) ;;
    open)    (cd "$dir" && mise run wt:open) >/dev/null 2>&1 & ;;
    new)
      [ -n "$query" ] || { run_here false; return; }
      (cd "$ROOT" && run_here mise run wt "$query")
      ;;
    *) die "unknown action $action" ;;
  esac
}

# Re-post the rows to fzf's --listen server until fzf has gone away.
cmd_refresh_loop() {
  local port="$1"
  while sleep "$REFRESH"; do
    curl -fsS -XPOST "http://127.0.0.1:$port" -d "reload($SELF rows)" >/dev/null 2>&1 || exit 0
  done
}

cmd_pick() {
  command -v fzf >/dev/null 2>&1 || die "wt:pick needs fzf (https://github.com/junegunn/fzf)"
  local keys='⏎ claude  ^n nvim  ^t shell  ^l logs  M-c console  ^u up  ^x stop  ^o browser  ^w new worktree from query  ^r refresh  ^/ preview'
  local reload="reload($SELF rows)"
  local -a live=()
  if [ "$REFRESH" != 0 ] && command -v curl >/dev/null 2>&1; then
    live=(--listen --bind "start:execute-silent($SELF refresh-loop \$FZF_PORT >/dev/null 2>&1 &)")
  fi
  WT_PICK_COLOR=1 "$SELF" rows | WT_PICK_COLOR=1 fzf \
    --ansi --delimiter=$'\t' --with-nth=2.. --no-sort --track --layout=reverse \
    --prompt='worktree> ' --header="$keys" \
    --preview="$SELF preview {1}" --preview-window='right,45%,wrap,<70(down,50%,wrap)' \
    --bind="enter:execute($SELF act claude {1})" \
    --bind="ctrl-n:execute($SELF act nvim {1})" \
    --bind="ctrl-t:execute($SELF act shell {1})" \
    --bind="ctrl-l:execute($SELF act logs {1})" \
    --bind="alt-c:execute($SELF act console {1})" \
    --bind="ctrl-u:execute($SELF act up {1})+$reload+refresh-preview" \
    --bind="ctrl-x:execute($SELF act stop {1})+$reload+refresh-preview" \
    --bind="ctrl-o:execute-silent($SELF act open {1})" \
    --bind="ctrl-w:execute($SELF act new {1} {q})+clear-query+$reload" \
    --bind="ctrl-r:$reload+refresh-preview" \
    --bind='ctrl-/:toggle-preview' \
    "${live[@]}" >/dev/null || true
}

case "${1:-}" in
  "")           cmd_pick ;;
  rows)         cmd_rows ;;
  preview)      shift; cmd_preview "$@" ;;
  act)          shift; cmd_act "$@" ;;
  refresh-loop) shift; cmd_refresh_loop "$@" ;;
  *) die "usage: $(basename "$0") [rows | preview <slug> | act <action> <slug> [query]]" ;;
esac
