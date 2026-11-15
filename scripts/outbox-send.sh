#!/bin/sh
# Sends every Markdown file in the outbox (default ~/kdash-outbox) to the Kindle inbox via inbox-send.sh.
# Run by launchd (com.abharosim.koreader-dash.outbox) every minute and when the folder changes.
#   exit 0 from inbox-send -> moved to sent/
#   exit 3 (Kindle unreachable) -> left in place for the next run
#   anything else -> moved to failed/
# The message id is the file name without .md, so a retry never duplicates a message.
# Gives up after 60 seconds. No 1Password: only KDASH_URL/KDASH_TOKEN from .env.
LIMIT=60
if [ -z "${KDASH_OUTBOX_ALARMED:-}" ]; then
    KDASH_OUTBOX_ALARMED=1 exec perl -e 'alarm shift; exec @ARGV' "$LIMIT" /bin/sh "$0" "$@"
fi
set -u
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
OUTBOX=${KDASH_OUTBOX:-$HOME/kdash-outbox}
mkdir -p "$OUTBOX/sent" "$OUTBOX/failed"
log() { echo "outbox: $(date '+%Y-%m-%d %H:%M:%S') $*"; }
now=$(date +%s)
for f in "$OUTBOX"/*.md; do
    [ -f "$f" ] || continue
    # Skip a file still being written; the next run picks it up.
    [ $((now - $(stat -f %m "$f"))) -ge 5 ] || { log "skip (just written) $(basename "$f")"; continue; }
    name=$(basename "$f" .md)
    id=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-64)
    result=$("$SCRIPTS/inbox-send.sh" --id "$id" --source dada --type briefing.daily "$f" 2>&1)
    rc=$?
    case $rc in
        0) mv -f "$f" "$OUTBOX/sent/"; log "sent $name: $result" ;;
        3) log "Kindle unreachable, will retry $name"; break ;;
        *) mv -f "$f" "$OUTBOX/failed/"; log "FAILED $name (exit $rc): $result" ;;
    esac
done
exit 0
