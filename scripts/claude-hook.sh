#!/bin/sh
# Claude Code hook: posts a message to the Kindle dashboard's inbox.
# Reads the hook's JSON on stdin. Configured for Notification and Stop in ~/.claude/settings.json.
# Never fails the hook: if the Kindle is asleep or unreachable, the message is skipped.
#
# Test: echo '{"hook_event_name":"Stop","cwd":"/tmp/demo","session_id":"abc"}' | scripts/claude-hook.sh

ENV_FILE="$(dirname "$0")/../.env"
[ -f "$ENV_FILE" ] || exit 0
. "$ENV_FILE"
[ -n "${KDASH_URL:-}" ] && [ -n "${KDASH_TOKEN:-}" ] || exit 0

input=$(cat)

# Builds the inbox message from the hook's input.
body=$(printf '%s' "$input" | jq -c '
    (.cwd // "") as $cwd
    | ($cwd | split("/") | last // "") as $project
    | (if $project == "" then "Claude Code" else $project end) as $name
    | (.session_id // "" | .[0:8]) as $session
    | (if $cwd == "" then "" else "\n\n`" + $cwd + "`" end) as $where
    | if .hook_event_name == "Notification" then {
          title: ("Needs you: " + $name),
          body: ((.message // "Claude Code is waiting for your input.")
                 + $where),
          priority: "high",
          type: "claude.attention"
      } else {
          title: ("Done: " + $name),
          body: ((.last_assistant_message // "Claude Code finished its turn.") as $text
                 | (if ($text | length) > 4000 then $text[0:4000] + "\n\n…" else $text end)
                 + $where),
          priority: "normal",
          type: "claude.stop"
      } end
    | . + { source: "claude", data: { session: $session, cwd: $cwd } }
' 2>/dev/null) || exit 0
[ -n "$body" ] || exit 0

curl -s -o /dev/null --max-time 4 \
    -X POST "$KDASH_URL/v1/inbox" \
    -H "Authorization: Bearer $KDASH_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary "$body" || true
exit 0
