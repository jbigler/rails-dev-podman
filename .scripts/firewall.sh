#!/usr/bin/env bash
# Inspect and adjust the per-container egress firewall that
# .container-config/firewall/hook.sh loads into each container's network
# namespace. Host side only: nothing inside a container can reach these rules.
#
#   show            every running firewalled container of this worktree (all
#                   worktrees from the workspace root): profiles, mode, and what
#                   was rejected -- or, in log mode, would have been. Also names
#                   any of the worktree's containers that run WITHOUT the
#                   firewall, which means the hook never fired.
#   allow SVC HOST… add hostnames/IPs to a running container's allowlist, e.g.
#                   `mise run fw:allow claude example.com`. Live only: gone on
#                   the next start. To keep it, use CLAUDE_FIREWALL_ALLOW (claude)
#                   or the profile's .container-config/firewall/*.allow file.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"
: "${PROJECT_PREFIX:?PROJECT_PREFIX unset (mise env not loaded)}"
P="$PROJECT_PREFIX"
W="${CURRENT_WORKTREE_NAME:-}"
STATE="$ROOT/.firewall/state"
TABLE=wt_firewall

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# podman unshare puts us in the rootless user namespace, where the container's
# network namespace can be entered with the needed privilege -- the same place
# the hook itself runs.
in_netns() { podman unshare nsenter -t "$1" -n "${@:2}"; }

# "addr proto port" per line from an nft set listing.
set_entries() {
  in_netns "$1" nft -n list set inet "$TABLE" "$2" 2>/dev/null \
    | tr -d '\n' \
    | sed -n 's/.*elements = {\([^}]*\)}.*/\1/p' \
    | tr ',' '\n' \
    | awk 'NF >= 5 { p = $3 == "6" ? "tcp" : $3 == "17" ? "udp" : $3; print $1, p, $5 }'
}

cmd_show() {
  # A container belongs to a worktree if it is on that worktree's dev network.
  # Names would miss podman-wt's transient exec containers, which have random
  # ones.
  local net="$P-[a-z0-9-]+-dev" any=0 id name nets f profiles mode
  [[ -n "$W" ]] && net="$P-$W-dev"
  local scope="(^|[^a-z0-9_-])${net}([^a-z0-9_-]|\$)"
  mkdir -p "$STATE"

  # State files of containers that no longer exist are noise; drop them.
  local live
  live="$(podman ps -a --no-trunc -q | cut -c1-12)"
  for f in "$STATE"/*; do
    [[ -f "$f" ]] || continue
    grep -qxF "$(basename "$f")" <<<"$live" || rm -f "$f"
  done

  while read -r id name nets; do
    [[ -n "$id" && "$nets" =~ $scope ]] || continue
    any=1
    f="$STATE/${id:0:12}"
    if [[ ! -f "$f" ]]; then
      # playwright keeps its own in-container firewall (init-firewall-playwright.sh).
      if [[ "$name" == *-playwright ]]; then
        printf '\n%s  own in-container firewall (init-firewall-playwright.sh)\n' "$name"
      else
        printf '\n%s  NO FIREWALL -- the hook did not run for this container.\n' "$name"
        printf '  Check: mise run doctor; then recreate it (mise run restart <svc>)\n'
      fi
      continue
    fi
    profiles="$(sed -n 's/^profiles=//p' "$f")"
    mode="$(sed -n 's/^mode=//p' "$f")"
    printf '\n%s  profiles=%s mode=%s\n' "$name" "$profiles" "$mode"
    [[ "$mode" == off ]] && continue
    local pid entries
    pid="$(podman inspect -f '{{.State.Pid}}' "$id")"
    entries="$( { set_entries "$pid" blocked4; set_entries "$pid" blocked6; } | sort -u)"
    if [[ -z "$entries" ]]; then
      printf '  nothing %s\n' "$([[ "$mode" == log ]] && echo 'would have been rejected' || echo rejected)"
      continue
    fi
    printf '  %s:\n' "$([[ "$mode" == log ]] && echo 'would reject under enforce' || echo rejected)"
    local addr proto port host
    while read -r addr proto port; do
      host="$(timeout 2 getent hosts "$addr" 2>/dev/null | awk '{ print $2; exit }')" || true
      printf '    %-40s %s/%s  %s\n' "$addr" "$proto" "$port" "${host:-}"
    done <<<"$entries"
  done < <(podman ps --format '{{.ID}} {{.Names}} {{.Networks}}')

  (( any )) || printf 'no running containers%s\n' "${W:+ for worktree $W}"
}

cmd_allow() {
  local svc="${1:-}"; shift || true
  [[ -n "$svc" && $# -gt 0 ]] || die "usage: mise run fw:allow <service> <host|ip>...  e.g. fw:allow claude example.com"
  [[ -n "$W" ]] || die "run from inside a worktree"
  local name="$P-$W-$svc" id pid ips=() h ip
  id="$(podman inspect -f '{{.Id}}' "$name" 2>/dev/null)" || die "$name is not running"
  [[ -f "$STATE/${id:0:12}" ]] || die "$name has no firewall to adjust"
  pid="$(podman inspect -f '{{.State.Pid}}' "$name")"
  for h in "$@"; do
    if [[ "$h" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
      ips+=("$h"); continue
    fi
    [[ "$h" =~ ^[A-Za-z0-9.-]+$ ]] || die "not a hostname: $h"
    while read -r ip; do ips+=("$ip"); done < <(getent ahostsv4 "$h" | awk '{ print $1 }' | sort -u)
    printf '%s -> %s\n' "$h" "$(getent ahostsv4 "$h" | awk '{ print $1 }' | sort -u | paste -sd' ' -)"
  done
  (( ${#ips[@]} )) || die "nothing resolved"
  in_netns "$pid" nft add element inet "$TABLE" allow4 "{ $(IFS=,; printf '%s' "${ips[*]}") }"
  printf 'allowed in %s until its next start\n' "$name"
}

case "${1:-}" in
  show)  cmd_show ;;
  allow) shift; cmd_allow "$@" ;;
  *) die "usage: $(basename "$0") {show|allow <service> <host|ip>...}" ;;
esac
