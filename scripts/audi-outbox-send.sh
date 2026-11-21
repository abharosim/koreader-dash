#!/bin/sh
# Sends every Markdown file dropped in ~/kdash-audi to the Kindle via audi-push.sh.
# Called from scripts/outbox-send.sh, so the existing launchd job delivers both
# the morning briefing and Audi. It does not look inside sent/ or failed/.
#   exit 0 from audi-push -> moved to sent/
#   exit 3 (Kindle unreachable) -> left in place; this run stops and the next retries
#   anything else -> moved to failed/
# A file touched less than 5 seconds ago is skipped, so a copy still in progress
# is not read. Write to a temporary name that does not end in .md, then rename.
set -u
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
AUDI=${KDASH_AUDI:-$HOME/kdash-audi}
mkdir -p "$AUDI/sent" "$AUDI/failed"
log() { echo "audi-outbox: $(date '+%Y-%m-%d %H:%M:%S') $*"; }
file_mtime() {
    if [ "$(uname)" = "Darwin" ]; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}
now=$(date +%s)
for f in "$AUDI"/*.md; do
    [ -f "$f" ] || continue
    # Skip a file still being written; the next run picks it up.
    [ $((now - $(file_mtime "$f"))) -ge 5 ] || { log "skip (just written) $(basename "$f")"; continue; }
    name=$(basename "$f" .md)
    result=$("$SCRIPTS/audi-push.sh" "$f" 2>&1)
    rc=$?
    case $rc in
        0) mv -f "$f" "$AUDI/sent/"; log "sent $name: $result" ;;
        3) log "Kindle unreachable, will retry $name"; break ;;
        *) mv -f "$f" "$AUDI/failed/"; log "FAILED $name (exit $rc): $result" ;;
    esac
done
exit 0
