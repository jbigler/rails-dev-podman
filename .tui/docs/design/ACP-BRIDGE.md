# acp-bridge ⇄ wt protocol (binding for both sides)

Transport: unix socket `/run/agent/acp.sock` in the agent@ container = `$ROOT/.run/<slug>/acp.sock` on the host
(`Config#acp_socket(slug)`), mode 0600, owned by the host user (keep-id). Newline-delimited JSON-RPC 2.0, one
JSON object per line, UTF-8. Everything that is not a `_bridge/*` method is relayed verbatim between the socket
and the adapter's stdio (the adapter is `AGENT_CMD`, default `claude-agent-acp`).

1. **Hello.** On accept, before anything else, the bridge sends
   `{"jsonrpc":"2.0","method":"_bridge/hello","params":{"agent":"<AGENT_NAME or basename of AGENT_CMD>","initialized":<bool>,"initializeResult":<cached initialize result or null>,"sessionId":<current session id or null>,"pending":<count of held agent→client requests>}}`.
2. **One client at a time.** A second concurrent connection receives
   `{"jsonrpc":"2.0","method":"_bridge/busy","params":{"holder":"<description of the attached client: peer pid/uid if available, and connected-at ISO time>"}}`
   and is closed. wt shows the session as `:busy` with that holder text.
3. **initialize.** The adapter is initialized once per container lifetime. If the bridge already holds an
   initialize result, a client's `initialize` request is answered by the bridge from cache with the client's
   request id and NOT forwarded. Otherwise it is forwarded and the result cached.
4. **Session id.** The bridge tracks the current session id from `session/new` / `session/load` results and
   reports it in hello. wt reuses it instead of creating a new session; `A` sends `session/new`.
5. **Request ids.** The bridge forwards ids unchanged. wt uses string ids `"wt-<random8>-<n>"` (fresh random
   per connection), so ids never collide across reconnects. Responses whose client has gone are logged and dropped.
6. **Held requests.** Agent→client requests (notably `session/request_permission`) that arrive while no client is
   attached — or that were sent to a client that disconnected without answering — are held. On the next
   connection the bridge re-sends every held request (original id) right after hello. A client response removes
   it from the held set. Notifications are never re-sent (wt rebuilds from the log).
7. **Capabilities.** wt's initialize sends `clientCapabilities: {fs: {readTextFile: false, writeTextFile: false}, terminal: false}`.
   If the adapter still sends an `fs/*` or `terminal/*` request, the bridge answers it with JSON-RPC error -32601.
8. **Log.** Every relayed message is appended to `/run/agent/session.jsonl` (host: `Config#session_log(slug)`) as
   `{"ts":"<ISO8601 UTC>","dir":"out"|"in","msg":<message>}` — `out` = adapter→client, `in` = client→adapter.
   `_bridge/*` messages are not logged. A new session (`session/new` result) appends
   `{"ts":...,"dir":"bridge","event":"session","sessionId":"..."}` so a replay can start from the latest session.
   For `session/load` the marker is written before the logged request, because the adapter replays the
   session's history as `session/update` notifications before it answers.
   wt rebuilds transcript, plan and tool calls by replaying from the last `bridge/session` event: `out`
   `session/update` notifications, `in` `session/prompt` requests (user text), and `out` responses carrying
   `stopReason`.
9. **Status file.** The bridge writes `/status/<WORKTREE_NAME>.json` (the existing status bind mount; temp file +
   rename, dotfile temp name) on every state change:
   `{"state":"working|waiting|permission|failed|offline","ts":"<ISO8601>","agent":"<name>","plan":{"done":N,"total":M}|null,"last":"<one line: latest tool call title or agent message, ≤120 chars>"}`.
   permission = a held/unanswered permission request; working = a `session/prompt` is in flight; failed = the
   last tool call failed or the adapter reported an error; waiting = idle; offline = adapter exited (written
   before the bridge exits). This file supersedes the claude hook's for that worktree; extra keys (e.g. `rtk`)
   from the hook format are optional.
10. **Adapter death.** If the adapter exits, the bridge writes offline status and exits non-zero (systemd
    restarts the unit). wt sees the socket close, marks the session `:ended`, shows "session ended", and offers
    `A`. On reconnect, if the cached initialize result advertises `agentCapabilities.loadSession` and the log
    holds a previous session id, wt sends `session/load` for it instead of `session/new`.
