#!/usr/bin/env bash
# Prove that no container can open a TCP connection to the dashboard's host
# port, 127.0.0.1:$WT_DASHBOARD_PORT. The dashboard runs on the host and can
# drive the worktree stacks, so a container that reaches it -- the agent, code
# rails hot-reloads, the playwright browser -- could act outside its sandbox.
#
# Probes, one line each (`blocked` or `REACHED`):
#   - a throwaway container on ${PROJECT_PREFIX}_proxy and on every
#     ${PROJECT_PREFIX}-<slug>-dev network, against every address a rootless
#     container could use for the host: host.containers.internal, the network's
#     gateway, 169.254.1.2 (pasta's host mapping) and 10.0.2.2 (slirp4netns').
#     These run without the egress firewall hook on purpose: the port must be
#     unreachable even from an unfirewalled container, not just a firewalled one.
#   - every running playwright container (no firewall hook, its own rules),
#     against its loopback and against wt.localhost as it resolves in there.
#
# Exit 0: nothing reached. 1: something reached (even if a later probe could
# not run). 2: could not probe -- a probe that never ran must not pass for one
# that was blocked.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
ROOT="$(find_project_root)"

# Exit 2 means "could not probe", but a probe that already REACHED the port
# outranks that: the check has its answer, and Task 11's verify maps 2 to a
# mere warning.
reached=0
die() { printf 'error: %s\n' "$*" >&2; exit $(( reached ? 1 : 2 )); }

[[ -n "${PROJECT_PREFIX:-}" ]] || die "PROJECT_PREFIX unset (mise env not loaded)"
[[ "${WT_DASHBOARD_PORT:-}" =~ ^[0-9]+$ ]] \
  || die "WT_DASHBOARD_PORT unset or not a port number (mise env not loaded)"
P="$PROJECT_PREFIX"
port="$WT_DASHBOARD_PORT"
command -v podman >/dev/null || die "podman not found"

host_listening() { (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; }

# A refused connection looks exactly like a blocked one, so something has to be
# listening or every probe would pass vacuously. Use the real dashboard when it
# is up, otherwise a throwaway listener for the duration of the check.
listener_pid=
cleanup() { [[ -z "$listener_pid" ]] || kill "$listener_pid" 2>/dev/null || true; }
trap cleanup EXIT
if ! host_listening; then
  # The dashboard's own pinned Ruby, not bare `ruby`: at the workspace root that
  # can be a mise shim with no version set. mise exec replaces itself with ruby,
  # so $! is the listener and the EXIT trap kills it.
  command -v mise >/dev/null || die "nothing listens on 127.0.0.1:$port and mise is not available to start a listener"
  mise exec ruby@4.0.7 -- ruby -rsocket -e 'TCPServer.new("127.0.0.1", ARGV[0].to_i).then { |s| loop { s.accept.close } }' "$port" &
  listener_pid=$!
  for _ in $(seq 50); do
    host_listening && break
    kill -0 "$listener_pid" 2>/dev/null || die "throwaway listener on 127.0.0.1:$port failed to start"
    sleep 0.1
  done
  host_listening || die "throwaway listener on 127.0.0.1:$port is not accepting connections"
fi

# Any worktree's rails image will do: it has bash and timeout. Read the tag
# straight out of the env file rather than sourcing it -- it holds the rest of
# that worktree's environment, POSTGRES_PASSWORD included.
img=
for f in "$ROOT"/.unit-env/*.env; do
  [[ -f "$f" ]] || continue
  candidate="$(sed -n 's/^RAILS_IMAGE=//p' "$f" | head -n1)"
  if [[ -n "$candidate" ]] && podman image exists "$candidate"; then
    img="$candidate"
    break
  fi
done
[[ -n "$img" ]] || die "no rails image to probe with; build an image first: mise run build"

# rc 0: the inner bash connected. 125: podman itself failed; 126/127: the probe
# command could not run. Those last three mean nothing was tested.
report() {
  local rc="$1" where="$2" target="$3"
  case "$rc" in
    0) printf 'REACHED  %s -> %s:%s\n' "$where" "$target" "$port"; reached=1 ;;
    125|126|127) die "probe $where -> $target:$port did not run (exit $rc)" ;;
    *) printf 'blocked  %s -> %s:%s\n' "$where" "$target" "$port" ;;
  esac
}

gateway() {
  podman network inspect "$1" --format '{{range .Subnets}}{{.Gateway}}{{end}}'
}

# --entrypoint "" as in podman-wt.sh, so the image's entrypoint never wraps the
# probe; --pull=never because the image was just confirmed to exist locally.
probe_network() {
  local net="$1" gw target rc
  gw="$(gateway "$net")" || die "cannot inspect network $net"
  [[ -n "$gw" ]] || die "network $net has no gateway to probe"
  for target in host.containers.internal "$gw" 169.254.1.2 10.0.2.2; do
    rc=0
    podman run --rm --pull=never --network "$net" --entrypoint "" "$img" \
      bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/$0/$1"' "$target" "$port" \
      >/dev/null 2>&1 || rc=$?
    report "$rc" "$net" "$target"
  done
}

podman network exists "${P}_proxy" \
  || die "no ${P}_proxy network to probe from; start the proxy: mise run proxy:up"
probe_network "${P}_proxy"

# Matched in bash, not with --filter: podman's name filter is an unanchored
# regex. Listed up front so a failing `podman network ls` stops the check
# instead of silently probing no dev network at all.
networks="$(podman network ls --format '{{.Name}}')" || die "cannot list podman networks"
while IFS= read -r net; do
  if [[ "$net" == "$P"-*-dev ]]; then probe_network "$net"; fi
done <<<"$networks"

probe_exec() {
  local ct="$1" target="$2" label="$3" rc=0
  podman exec "$ct" bash -c 'timeout 3 bash -c "exec 3<>/dev/tcp/$0/$1"' "$target" "$port" \
    >/dev/null 2>&1 || rc=$?
  report "$rc" "$ct" "$label"
}

playwrights="$(podman ps --filter "name=^${P}-.*-playwright\$" --format '{{.Names}}')" \
  || die "cannot list running containers"
while IFS= read -r ct; do
  [[ -n "$ct" ]] || continue
  probe_exec "$ct" 127.0.0.1 127.0.0.1
  # Resolved inside the container, where --add-host and its /etc/hosts decide
  # what wt.localhost means. getent's own status, not the pipeline's: 2 is "key
  # not found", which cannot be connected to and so counts as blocked; anything
  # else non-zero (container gone: 125, no getent: 127) means nothing was tested.
  rc=0
  hosts="$(podman exec "$ct" getent hosts wt.localhost 2>/dev/null)" || rc=$?
  case "$rc" in
    0)
      wt_addr="$(awk 'NR == 1 { print $1 }' <<<"$hosts")"
      [[ -n "$wt_addr" ]] || die "getent in $ct returned no address for wt.localhost"
      probe_exec "$ct" "$wt_addr" "wt.localhost($wt_addr)"
      ;;
    2) printf 'blocked  %s -> wt.localhost:%s (does not resolve)\n' "$ct" "$port" ;;
    *) die "probe $ct -> wt.localhost:$port did not run (getent exit $rc)" ;;
  esac
done <<<"$playwrights"

exit "$reached"
