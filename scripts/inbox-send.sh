#!/bin/sh
# Posts a Markdown file to the Kindle dashboard's inbox.
#
# Usage: scripts/inbox-send.sh [--title T] [--id ID] [--priority low|normal|high] [--source S] [--type T] FILE.md
#        FILE may be - to read stdin.
# Title defaults to the file's first "# " heading, else the file name.
# Pass --id (e.g. briefing-2026-11-15) to make retries safe: resending the same id is a no-op.
# Exit 0 on 200/201; otherwise prints the device's error and exits 1 (2 for bad usage, 3 if unreachable).
set -u
title="" id="" priority="normal" source="" type=""
while [ $# -gt 0 ]; do
    case "$1" in
        --title) title=$2; shift 2 ;;
        --id) id=$2; shift 2 ;;
        --priority) priority=$2; shift 2 ;;
        --source) source=$2; shift 2 ;;
        --type) type=$2; shift 2 ;;
        -h|--help) sed -n 2,9p "$0"; exit 0 ;;
        --) shift; break ;;
        -?*) echo "inbox-send: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -eq 1 ] || { echo "inbox-send: give exactly one FILE (or -)" >&2; exit 2; }
file=$1

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -n "${KDASH_URL:-}" ] && [ -n "${KDASH_TOKEN:-}" ] || { echo "inbox-send: KDASH_URL and KDASH_TOKEN must be set (in .env)" >&2; exit 2; }

tmp=$(mktemp); out=$(mktemp); trap 'rm -f "$tmp" "$out"' EXIT
if [ "$file" = "-" ]; then cat > "$tmp"; else [ -f "$file" ] || { echo "inbox-send: no such file $file" >&2; exit 2; }; cat "$file" > "$tmp"; fi
size=$(wc -c < "$tmp" | tr -d ' ')
[ "$size" -le 262144 ] || { echo "inbox-send: body is $size bytes; the limit is 256 KB" >&2; exit 2; }
if [ -z "$title" ]; then
    title=$(sed -n 's/^# \{1,\}//p' "$tmp" | head -n 1)
    [ -n "$title" ] || title=$(basename "$file" .md)
    [ "$file" = "-" ] && [ -z "$title" ] && title="Message"
fi

jq -n --arg title "$title" --rawfile body "$tmp" --arg id "$id" --arg priority "$priority" \
      --arg source "$source" --arg type "$type" '
    {title: $title, body: $body, priority: $priority}
    + (if $id == "" then {} else {id: $id} end)
    + (if $source == "" then {} else {source: $source} end)
    + (if $type == "" then {} else {type: $type} end)' > "$out.json" || { rm -f "$out.json"; exit 2; }

code=$(curl -sS -o "$out" -w '%{http_code}' --max-time 15 -X POST "$KDASH_URL/v1/inbox" \
    -H "Authorization: Bearer $KDASH_TOKEN" -H "Content-Type: application/json" \
    --data-binary "@$out.json") || { rm -f "$out.json"; echo "inbox-send: Kindle unreachable at $KDASH_URL" >&2; exit 3; }
rm -f "$out.json"
case "$code" in
    200|201) echo "inbox-send: $code $(cat "$out")"; exit 0 ;;
    *) echo "inbox-send: HTTP $code $(cat "$out")" >&2; exit 1 ;;
esac
