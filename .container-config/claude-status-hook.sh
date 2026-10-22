#!/bin/sh
# Claude Code hook: record this worktree's claude session state for the web
# dashboard. Registered for several hook events by entrypoint-claude.sh; the
# event name arrives in the JSON payload on stdin. Writes
# /status/<worktree>.json -- a bind mount of .container-config/status/, which
# the web dashboard reads from disk.
#
# The file keeps the original fields the web dashboard reads (state, ts, rtk)
# and adds v2 fields: phase, event, notification_type, message, tool,
# last_message. Each event updates the previous file, so fields an event does
# not set keep their values (e.g. last_message survives an idle notification).
#
# WT_HOOK_DEBUG=1 also saves the raw payload to /status/.<worktree>.<event>.json
# (the dashboard reads only <worktree>.json, so it never sees these).
# WT_STATUS_DIR overrides /status, for tests.
set -eu

dir="${WT_STATUS_DIR:-/status}"
[ -n "${WORKTREE_NAME:-}" ] && [ -d "$dir" ] || exit 0

in=$(mktemp)
tmp=""
# Exit 2 from a UserPromptSubmit or PreToolUse hook blocks the prompt or the
# tool. Recording status must never do that, so any failure exits 1: Claude
# reports it and carries on.
trap 'status=$?; rm -f "$in" ${tmp:+"$tmp"}; [ "$status" = 0 ] || exit 1' EXIT
cat > "$in"

event=$(jq -r '.hook_event_name // empty' "$in" 2>/dev/null || true)
case "$event" in
  UserPromptSubmit | PreToolUse | PostToolUse) state="working" ;;
  SessionStart | Stop | Notification | PermissionRequest) state="waiting" ;;
  SessionEnd) state="offline" ;;
  *) exit 0 ;;
esac

[ "${WT_HOOK_DEBUG:-}" = 1 ] && cp "$in" "$dir/.${WORKTREE_NAME}.${event}.json"

# RTK token savings for this worktree. rtk's history DB lives in this
# container's per-worktree home, so the global figure is already scoped to this
# worktree. ~4ms; falls back to null so a missing or broken rtk never costs us
# the status file.
rtk=$(rtk gain --format json 2>/dev/null \
  | jq -cs 'if length == 1 then .[0].summary // null else null end' 2>/dev/null) || rtk="null"
[ -n "$rtk" ] || rtk="null"

# Exactly one JSON object, else {}: an empty, cut-off or doubled file must
# never reach --argjson, where it would fail every later event too.
file="$dir/${WORKTREE_NAME}.json"
prev="{}"
[ -f "$file" ] && { prev=$(jq -cs 'if length == 1 and (.[0] | type) == "object" then .[0] else {} end' "$file" 2>/dev/null) || prev="{}"; }
[ -n "$prev" ] || prev="{}"

# Temp + rename so the dashboard never reads a half-written file. A temp of its
# own: subagents fire these hooks alongside the main session, and a shared name
# let one hook rename another's half-written temp into place.
tmp=$(mktemp "$dir/.${WORKTREE_NAME}.XXXXXX")
jq -c \
  --argjson prev "$prev" \
  --argjson rtk "$rtk" \
  --arg state "$state" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  # Markdown flattened to one line: fences, bold, backticks, heading and list markers.
  def flat:
    gsub("```[\\s\\S]*?```"; " ")
    | gsub("\\*\\*|`"; "")
    | gsub("(?m)^[ \\t]*(#+|[-*]|\\d+\\.)[ \\t]+"; "")
    | gsub("\\s+"; " ")
    | sub("^ "; "") | sub(" $"; "");
  def tail($n): if length > $n then "… " + (.[length - $n:] | sub("^ "; "")) else . end;
  def rel($cwd): if $cwd != "" and startswith($cwd + "/") then .[($cwd | length) + 1:] else . end;
  def question: (.tool_input.questions // [])[0].question // "Claude has a question";
  def summary:
    (.cwd // "") as $cwd
    | (.tool_input // {}) as $t
    | if .tool_name == "Bash" then
        "Bash: " + (($t.command // "") | split("\n")[0] | .[0:80])
      elif (.tool_name | IN("Edit", "Write", "Read", "MultiEdit", "NotebookEdit")) then
        .tool_name + " " + (($t.file_path // $t.notebook_path // "") | rel($cwd))
      else
        (.tool_name // "tool")
      end;
  ($prev + {state: $state, ts: $ts, rtk: $rtk, v: 2, event: .hook_event_name}) as $base
  | if .hook_event_name == "SessionStart" then
      $base + {phase: "idle", message: null, tool: null, last_message: null, notification_type: null}
    elif .hook_event_name == "UserPromptSubmit" then
      $base + {phase: "working", message: null, tool: null, last_message: null, notification_type: null}
    elif .hook_event_name == "PreToolUse" or .hook_event_name == "PermissionRequest" then
      if .tool_name == "AskUserQuestion" then
        # AskUserQuestion fires PermissionRequest too, even with bypassPermissions.
        $base + {phase: "question", message: question}
      elif .hook_event_name == "PermissionRequest" then
        $base + {phase: "permission", message: ("Permission: " + summary)}
      else
        $base + {phase: "working", tool: summary, message: null}
      end
    elif .hook_event_name == "PostToolUse" then
      $base + {phase: "working", message: null}
    elif .hook_event_name == "Notification" then
      ($base + {notification_type: (.notification_type // null)}) as $n
      | if .notification_type == "permission_prompt" then
          $n + {phase: "permission", message: (.message // "Claude needs your permission")}
        elif (.notification_type // "" | startswith("elicitation_dialog")) then
          $n + {phase: "question", message: (.message // "Claude has a question")}
        elif .notification_type == "idle_prompt" then
          if ($prev.phase // "") | IN("done", "question", "permission") then $n else $n + {phase: "idle"} end
        else
          $n
        end
    elif .hook_event_name == "Stop" then
      $base + {phase: "done", message: null,
               last_message: ((.last_assistant_message // "") | flat | tail(600) | if . == "" then null else . end)}
    else
      $base + {phase: "offline"}
    end
' "$in" > "$tmp"
chmod 644 "$tmp" # mktemp's 0600; the dashboard reads it on the host
mv "$tmp" "$file"
