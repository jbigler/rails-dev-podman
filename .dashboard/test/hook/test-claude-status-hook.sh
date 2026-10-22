#!/bin/sh
# Replays hook payloads through claude-status-hook.sh and checks the status file
# after each one. Usage: sh test-claude-status-hook.sh [path/to/claude-status-hook.sh]
# Payload fixtures are read from ../fixtures/hook-payloads/.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
hook=${1:-$here/../../../.container-config/claude-status-hook.sh}
p=$here/../fixtures/hook-payloads
dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
export WT_STATUS_DIR="$dir" WORKTREE_NAME=general-work
f="$dir/general-work.json"
fail=0

run() { sh "$hook" < "$1"; }
check() { # check "<description>" '<jq boolean expression>'
  if jq -e "$2" "$f" >/dev/null; then echo "ok   - $1"
  else echo "FAIL - $1"; echo "       expected: $2"; echo "       file: $(cat "$f")"; fail=1; fi
}

# An existing v1 file, as written by the old hook.
echo '{"state":"offline","ts":"2026-10-20T13:40:45Z","rtk":null}' > "$f"

run "$p/SessionStart.json"
check "SessionStart: idle, legacy state waiting" '.v == 2 and .phase == "idle" and .state == "waiting" and .last_message == null'

run "$p/UserPromptSubmit.json"
check "UserPromptSubmit: working" '.phase == "working" and .state == "working"'

run "$p/PreToolUse.Bash.json"
check "PreToolUse Bash: tool summary" '.phase == "working" and .tool == "Bash: ls -la"'

run "$p/PreToolUse.Edit.json"
check "PreToolUse Edit: path relative to the worktree" '.tool == "Edit app/models/user.rb"'

run "$p/PreToolUse.json"
check "PreToolUse AskUserQuestion: question" '.phase == "question" and .message == "What should we work on next?"'

run "$p/PermissionRequest.json"
check "PermissionRequest for AskUserQuestion stays a question" '.phase == "question" and .message == "What should we work on next?" and .state == "waiting"'

run "$p/PostToolUse.json"
check "PostToolUse after the answer: working, message cleared" '.phase == "working" and .message == null'

run "$p/Stop.json"
check "Stop: done with last message" '.phase == "done" and .last_message == "Hello." and .state == "waiting"'

run "$p/Notification.json"
check "idle_prompt after Stop keeps done and the last message" '.phase == "done" and .last_message == "Hello." and .notification_type == "idle_prompt"'

run "$p/Stop.long.json"
check "Stop: long markdown flattened, tail kept, end visible" '(.last_message | startswith("… ")) and (.last_message | endswith("Want me to start it and run them?")) and (.last_message | length) <= 602 and (.last_message | test("```|\\*\\*") | not)'

run "$p/PermissionRequest.Bash.json"
check "PermissionRequest for a real tool: permission" '.phase == "permission" and .message == "Permission: Bash: bin/rails db:migrate"'

run "$p/Notification.permission_prompt.json"
check "permission_prompt notification: permission + message" '.phase == "permission" and .message == "Claude needs your permission to use Bash"'

run "$p/UserPromptSubmit.json"
check "next prompt clears message and last message" '.phase == "working" and .message == null and .last_message == null'

run "$p/Notification.json"
check "idle_prompt while working (no Stop seen): idle" '.phase == "idle"'

run "$p/SessionEnd.json"
check "SessionEnd: offline" '.phase == "offline" and .state == "offline"'

check "web dashboard fields still present" 'has("state") and has("ts") and has("rtk")'

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
