#!/bin/sh
# Installs the plugin on the Kindle over SSH, then verifies every file.
# Then asks KOReader to restart so the new code loads, and to open Dash once it's back;
# pass --no-restart to skip both.
# The restart needs the plugin already running, so the very first install needs a manual one.
set -eu
cd "$(dirname "$0")/.."
HOST="${KINDLE_HOST:-root@192.168.1.152}"
PORT="${KINDLE_PORT:-2222}"
KEY="${KINDLE_KEY:-$HOME/.ssh/mac_mini_anasim}"
PLUGINS=/mnt/us/koreader/plugins
kindle() { ssh -i "$KEY" -p "$PORT" -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@"; }

# COPYFILE_DISABLE stops macOS adding ._ metadata files to the archive.
COPYFILE_DISABLE=1 tar -C plugin/dash.koplugin -cf - . | kindle "
    set -e
    rm -rf $PLUGINS/.dash.new
    mkdir $PLUGINS/.dash.new
    tar -C $PLUGINS/.dash.new -xf -
    rm -rf $PLUGINS/dash.koplugin
    mv $PLUGINS/.dash.new $PLUGINS/dash.koplugin
"

for path in plugin/dash.koplugin/*.lua; do
    name=$(basename "$path")
    local_sum=$(md5 -q "$path")
    remote_sum=$(kindle "md5sum $PLUGINS/dash.koplugin/$name" | cut -d' ' -f1)
    if [ "$local_sum" != "$remote_sum" ]; then
        echo "Checksum mismatch: $name" >&2
        exit 1
    fi
    echo "verified $name"
done
echo "Installed to $HOST:$PLUGINS/dash.koplugin"

[ "${1:-}" = "--no-restart" ] && exit 0
REQUEST=/mnt/us/koreader/settings/dash_restart_request
# Read by the new code on startup: it opens Dash and deletes the file.
kindle "touch /mnt/us/koreader/settings/dash_open_request && touch $REQUEST"
# The plugin deletes the request when it acts on it, within a couple of seconds.
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    # Needs an explicit answer: a dropped SSH connection proves nothing.
    if [ "$(kindle "[ -e $REQUEST ] && echo waiting || echo gone" 2>/dev/null)" = "gone" ]; then
        echo "KOReader is restarting"
        exit 0
    fi
done
echo "KOReader didn't pick up the restart request (asleep, or running older code?). Restart it by hand." >&2
exit 1
