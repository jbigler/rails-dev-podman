#!/bin/bash
# OCI createRuntime hook: egress firewall for one worktree container, applied
# from OUTSIDE it.
#
# The container never holds NET_ADMIN, so nothing running inside -- an agent,
# code it wrote that rails hot-reloads, an npm postinstall -- can change its own
# rules. (The claude container used to build its firewall itself through a
# sudo rule that accepted any domain as an argument, so the agent could allow
# whatever it liked.) A failing hook fails the container start: fail closed.
#
# Wiring: units:install renders hook.json into .firewall/hooks.d/. Units pass
# --hooks-dir there plus these annotations, and the hook fires only when the
# first is present:
#   <prefix>.firewall        comma list of profiles: none | deps | agent
#                            (each but none names <profile>.allow here)
#   <prefix>.firewall.mode   enforce: reject what is not allowed
#                            log:     allow everything, record what enforce
#                                     would reject (mise run fw:show)
#                            off:     no rules at all
#   <prefix>.firewall.networks  comma list of the podman networks the container
#                            joins; their subnets are what "local" means
#   <prefix>.firewall.extra  optional extra hostnames/IPs, comma or space separated
#
# crun runs hooks inside podman's rootless user namespace, where this process
# is uid 0 with CAP_NET_ADMIN over the container's network namespace, so plain
# nsenter + nft works. Hostnames are resolved here, by the host, once per
# start: no DNS reaches the container's allowlist from inside it.
#
# Always allowed: loopback, replies, and the subnets of the networks named in
# <prefix>.firewall.networks -- the worktree's dev network (db, redis, rustfs,
# playwright, aardvark DNS at the gateway) and the proxy network (Traefik).
# They are read from netavark's config files (NETWORK_DIR, rendered into
# hook.json), not from the netns: for a UserNS=keep-id container podman
# configures the network only AFTER the OCI create, so at createRuntime the
# netns has no routes yet. Known gap: aardvark-dns forwards any name upstream,
# so DNS itself remains a narrow exfil channel.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
STATE="$ROOT/.firewall/state"
LOG="$ROOT/.firewall/hook.log"
P="${1:?usage: hook.sh <project-prefix>  (OCI state JSON on stdin)}"
TABLE=wt_firewall

mkdir -p "$STATE"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
die() { log "error: ${cid:-?} $*"; printf 'firewall hook: %s\n' "$*" >&2; exit 1; }

oci="$(cat)"

# The OCI state is flat JSON with string annotation values; the fields needed
# are matched directly rather than requiring jq on the host.
field_num() { [[ "$oci" =~ \"$1\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
field_str() {
  local key="${1//./\\.}"
  [[ "$oci" =~ \"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
}

pid="$(field_num pid)" || die "no pid in the OCI state"
cid="$(field_str id)" || die "no id in the OCI state"
cid="${cid:0:12}"
profiles="$(field_str "$P.firewall")" || die "no $P.firewall annotation"
mode="$(field_str "$P.firewall.mode")" || true
extra="$(field_str "$P.firewall.extra")" || true
networks="$(field_str "$P.firewall.networks")" || true

case "$mode" in
  enforce|log|off) ;;
  "") die "$P.firewall.mode is empty -- the unit env file predates the firewall; run: mise run units:env" ;;
  *) die "$P.firewall.mode=$mode; expected enforce, log or off" ;;
esac

if [[ "$mode" == off ]]; then
  printf 'profiles=%s\nmode=off\n' "$profiles" >"$STATE/$cid"
  log "$cid pid=$pid profiles=$profiles mode=off: no rules"
  exit 0
fi

files=()
IFS=, read -ra plist <<<"$profiles"
for p in "${plist[@]}"; do
  case "$p" in
    none) ;;
    deps|agent) files+=("$HERE/$p.allow") ;;
    *) die "unknown firewall profile '$p' in $P.firewall=$profiles" ;;
  esac
done

ipv4='^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'
allow=()      # IPv4 addresses and CIDRs
labels=()     # "address name" pairs for fw:show
unresolved=()

add() { allow+=("$1"); labels+=("$1 $2"); }

# GitHub and Datadog publish their ranges; resolving one hostname would miss
# most of them. Needs curl and jq on the host; without them, or offline, the
# entry is skipped and named in the log.
meta_ranges() {
  local url filter json cidr
  case "$1" in
    github)       url=https://api.github.com/meta
                  filter='(.web + .api + .git)[]' ;;
    datadog-us5)  url=https://ip-ranges.us5.datadoghq.com/api.json
                  filter='.api.prefixes_ipv4[]' ;;
    *) unresolved+=("meta:$1 (unknown)"); return 0 ;;
  esac
  if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
    unresolved+=("meta:$1 (needs curl and jq)"); return 0
  fi
  json="$(curl -fsS --max-time 15 "$url" 2>/dev/null)" || { unresolved+=("meta:$1 (fetch failed)"); return 0; }
  while read -r cidr; do
    [[ "$cidr" =~ $ipv4 ]] && add "$cidr" "meta:$1"
  done < <(jq -r "$filter" <<<"$json" 2>/dev/null)
}

resolve() {
  local name="$1" ip found=""
  [[ "$name" =~ ^[A-Za-z0-9.-]+$ ]] || { unresolved+=("$name (not a hostname)"); return 0; }
  while read -r ip; do
    [[ "$ip" =~ $ipv4 ]] || continue
    add "$ip" "$name"; found=1
  done < <(getent ahostsv4 "$name" 2>/dev/null | awk '{ print $1 }' | sort -u)
  [[ -n "$found" ]] || unresolved+=("$name")
}

entry() {
  case "$1" in
    meta:*) meta_ranges "${1#meta:}" ;;
    *) if [[ "$1" =~ $ipv4 ]]; then add "$1" literal; else resolve "$1"; fi ;;
  esac
}

wanted=0
for f in ${files[@]+"${files[@]}"}; do
  [[ -f "$f" ]] || die "missing allowlist $f"
  while read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    wanted=1; entry "$line"
  done <"$f"
done
read -ra extras <<<"${extra//,/ }"
for e in ${extras[@]+"${extras[@]}"}; do wanted=1; entry "$e"; done

# A profile that wanted addresses and got none means host DNS or the network
# is down. Enforcing would start a container that cannot reach anything it
# needs, so say so instead.
if [[ "$mode" == enforce && "$wanted" == 1 && ${#allow[@]} -eq 0 ]]; then
  die "profiles=$profiles resolved to no addresses (host DNS down?): ${unresolved[*]}"
fi
# Hostnames often share addresses (rubygems.org and index.rubygems.org).
if (( ${#allow[@]} )); then
  mapfile -t allow < <(printf '%s\n' "${allow[@]}" | sort -u)
fi

# netavark's own record of each network: "subnets": [ { "subnet": "10.89.0.0/24", ...
local4=()
[[ -d "${NETWORK_DIR:-}" ]] || die "NETWORK_DIR=${NETWORK_DIR:-} is not a directory -- rerun: mise run units:install"
IFS=, read -ra netlist <<<"$networks"
(( ${#netlist[@]} )) || die "no $P.firewall.networks annotation -- recreate the container from current units (mise run units:install, then restart)"
for n in "${netlist[@]}"; do
  [[ "$n" =~ ^[A-Za-z0-9_.-]+$ ]] || die "bad network name '$n'"
  [[ -f "$NETWORK_DIR/$n.json" ]] || die "network $n has no config at $NETWORK_DIR/$n.json"
  while read -r net; do
    [[ "$net" =~ $ipv4 ]] && local4+=("$net")
  done < <(grep -oE '"subnet"[[:space:]]*:[[:space:]]*"[^"]+"' "$NETWORK_DIR/$n.json" | grep -oE '[0-9.]+/[0-9]+')
done

elements() { (( $# )) || return 0; printf 'elements = { %s }' "$(IFS=,; printf '%s' "$*")"; }

if [[ "$mode" == enforce ]]; then
  verdict='reject with icmpx admin-prohibited'
else
  verdict='accept'
fi

ruleset="$(cat <<EOF
table inet $TABLE
delete table inet $TABLE
table inet $TABLE {
  set allow4 { type ipv4_addr; flags interval; auto-merge; $(elements ${allow[@]+"${allow[@]}"}) }
  set local4 { type ipv4_addr; flags interval; auto-merge; $(elements ${local4[@]+"${local4[@]}"}) }
  # Everything that met the final verdict: rejected under enforce, would have
  # been under log. Read by fw:show; entries age out after a week.
  set blocked4 { type ipv4_addr . inet_proto . inet_service; flags dynamic,timeout; timeout 7d; size 4096; }
  set blocked6 { type ipv6_addr . inet_proto . inet_service; flags dynamic,timeout; timeout 7d; size 4096; }
  chain output {
    type filter hook output priority filter; policy accept;
    oif "lo" accept
    ct state established,related accept
    ip daddr @local4 accept
    ip daddr @allow4 accept
    # Neighbour discovery and other link-local IPv6 housekeeping.
    ip6 daddr { fe80::/10, ff02::/16 } accept
    meta l4proto { tcp, udp } meta nfproto ipv4 add @blocked4 { ip daddr . meta l4proto . th dport }
    meta l4proto { tcp, udp } meta nfproto ipv6 add @blocked6 { ip6 daddr . meta l4proto . th dport }
    $verdict
  }
}
EOF
)"

nsenter -t "$pid" -n nft -f - <<<"$ruleset" 2>>"$LOG" || die "nft rejected the ruleset for pid $pid (see $LOG)"

{
  printf 'profiles=%s\nmode=%s\n' "$profiles" "$mode"
  printf 'label %s\n' ${labels[@]+"${labels[@]}"}
} >"$STATE/$cid"
log "$cid pid=$pid profiles=$profiles mode=$mode allow=${#allow[@]} local=${local4[*]:-none}${unresolved[*]:+ unresolved: ${unresolved[*]}}"
