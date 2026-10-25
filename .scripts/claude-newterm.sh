#!/usr/bin/env bash
# Launch the Claude container outside the current shell, preferring a tab of the
# terminal we are already running in (newterm.sh holds the escalation ladder).
#
# podman-claude.sh reads CLAUDE_NO_TOKEN from the environment itself, so there
# is no flag list to forward -- the exported variable crosses into the new
# terminal with the rest of the mise env.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$dir/newterm.sh" --title Claude -- "$dir/podman-claude.sh" "$@"
