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

# --- Never blocks Claude: exit 2 from a UserPromptSubmit/PreToolUse hook blocks
# the prompt or tool, so bad state must not turn into jq's exit 2.
status_of() { set +e; sh "$hook" < "$1" 2>/dev/null; echo $?; set -e; }
expect() { # expect "<description>" <status> '<jq boolean expression>'
  if [ "$2" = 0 ] && jq -e "$3" "$f" >/dev/null 2>&1; then echo "ok   - $1"
  else echo "FAIL - $1 (exit $2)"; echo "       file: $(cat "$f" 2>/dev/null)"; fail=1; fi
}

: > "$f"
expect "an empty status file starts fresh" "$(status_of "$p/UserPromptSubmit.json")" '.phase == "working" and .v == 2'

printf '%s\n%s\n' '{"phase":"done"}' '{"phase":"idle"}' > "$f"
expect "two concatenated status documents start fresh" "$(status_of "$p/UserPromptSubmit.json")" '.phase == "working"'

bin=$(mktemp -d)
printf '#!/bin/sh\necho %s\necho %s\n' "'{\"summary\":{\"total_commands\":1}}'" "'{\"summary\":{\"total_commands\":2}}'" > "$bin/rtk"
chmod +x "$bin/rtk"
expect "rtk printing two documents gives rtk null" "$(PATH="$bin:$PATH" status_of "$p/PreToolUse.Bash.json")" '.rtk == null and .tool == "Bash: ls -la"'
printf '#!/bin/sh\necho %s\n' "'{\"summary\":{\"total_commands\":3}}'" > "$bin/rtk"
expect "rtk's summary is kept" "$(PATH="$bin:$PATH" status_of "$p/PreToolUse.Bash.json")" '.rtk.total_commands == 3'
rm -rf "$bin"

# Subagents fire hooks alongside the main session, in the same worktree.
statuses=$(mktemp)
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  for e in UserPromptSubmit PreToolUse.Bash PostToolUse; do
    (set +e; sh "$hook" < "$p/$e.json" 2>/dev/null; echo $? >> "$statuses") &
  done
done
wait
if [ "$(sort -u "$statuses")" = 0 ] && jq -e '.v == 2' "$f" >/dev/null 2>&1 && [ -z "$(find "$dir" -name '.general-work.*' ! -name '*.lock')" ]; then
  echo "ok   - 60 concurrent hooks: all exit 0, the file is whole, no temp files left"
else
  echo "FAIL - concurrent hooks: exits $(sort "$statuses" | uniq -c | tr '\n' ' ')"; echo "       file: $(cat "$f")"; ls -a "$dir"; fail=1
fi
rm -f "$statuses"

chmod 555 "$dir"
s=$(status_of "$p/UserPromptSubmit.json")
chmod 755 "$dir"
if [ "$s" != 2 ] && [ "$s" != 0 ]; then echo "ok   - a failure exits $s (reported), never 2 (blocks)"; else echo "FAIL - unwritable status dir exits $s"; fail=1; fi

[ "$fail" = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
