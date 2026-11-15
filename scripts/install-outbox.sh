#!/bin/sh
# Installs the launchd job that sends ~/kdash-outbox/*.md to the Kindle inbox every 10 minutes.
# Log: ~/Library/Logs/koreader-dash-outbox.log
#   scripts/install-outbox.sh             install (or reinstall) and run once now
#   scripts/install-outbox.sh --uninstall stop it and remove the job (the outbox folder is kept)
set -eu
cd "$(dirname "$0")/.."
REPO=$(pwd)
LABEL=com.abharosim.koreader-dash.outbox
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/kdash-outbox/sent" "$HOME/kdash-outbox/failed"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" "scripts/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart "$DOMAIN/$LABEL"
echo "Installed $LABEL: runs at login, every 10 minutes, and when ~/kdash-outbox changes"
echo "Log: $HOME/Library/Logs/koreader-dash-outbox.log"
