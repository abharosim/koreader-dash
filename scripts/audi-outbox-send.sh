#!/bin/sh
# Sends every Markdown file dropped in ~/kdash-audi to the Kindle via audi-push.sh.
# Called from scripts/outbox-send.sh, so the existing launchd job delivers both
# the morning briefing and Audi. It does not look inside sent/ or failed/.
#   exit 0 from audi-push -> moved to sent/
#   exit 3 (Kindle unreachable) -> left in place; this run stops and the next retries
#   anything else -> moved to failed/
# A producer may write straight to name.md (no temp-file rename). Before sending,
# size and mtime are sampled, then sampled again after about 2 seconds. A file
# that changed, or was modified in the last 5 seconds, stays in place for the
# next run and is never moved to failed/. Dotfiles (including .name.tmp) are ignored,
# so a rename into place still works.
set -u
SCRIPTS=$(cd "$(dirname "$0")" && pwd)
AUDI=${KDASH_AUDI:-$HOME/kdash-audi}
STABLE_WAIT=${KDASH_AUDI_STABLE_WAIT:-2}
mkdir -p "$AUDI/sent" "$AUDI/failed"
log() { echo "audi-outbox: $(date '+%Y-%m-%d %H:%M:%S') $*"; }
file_stat() {
    # "mtime size" — mtime in seconds, size in bytes.
    if [ "$(uname)" = "Darwin" ]; then
        stat -f '%m %z' "$1"
    else
        stat -c '%Y %s' "$1"
    fi
}
# 0 when the file has held still and is not brand new. Anything else: leave it.
ready_to_send() {
    target=$1
    base=$(basename "$target")
    case "$base" in
        .*) log "skip (dotfile) $base"; return 1 ;;
    esac
    [ -f "$target" ] || { log "skip (gone) $base"; return 1; }
    stat_line=$(file_stat "$target") || { log "skip (gone) $base"; return 1; }
    mtime1=${stat_line%% *}
    size1=${stat_line#* }
    sleep "$STABLE_WAIT"
    if [ ! -f "$target" ]; then
        log "skip (gone) $base"
        return 1
    fi
    stat_line=$(file_stat "$target") || { log "skip (gone) $base"; return 1; }
    mtime2=${stat_line%% *}
    size2=${stat_line#* }
    if [ "$size1" != "$size2" ] || [ "$mtime1" != "$mtime2" ]; then
        log "skip (still changing) $base"
        return 1
    fi
    now=$(date +%s)
    if [ $((now - mtime2)) -lt 5 ]; then
        log "skip (just written) $base"
        return 1
    fi
    return 0
}
for f in "$AUDI"/*.md; do
    [ -f "$f" ] || continue
    ready_to_send "$f" || continue
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
