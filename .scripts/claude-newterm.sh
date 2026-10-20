#!/usr/bin/env bash
# Claude for this worktree in its own tab, one per worktree: a second call
# focuses the tab the first one opened (see newterm.sh).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# podman-claude.sh reads CLAUDE_NO_TOKEN from the environment itself, so there
# is no flag list to forward -- the exported variable crosses into the new
# terminal with the rest of the mise env.
exec "$here/newterm.sh" --title "claude:${CURRENT_WORKTREE_NAME:-?}" -- "$here/podman-claude.sh" "$@"
