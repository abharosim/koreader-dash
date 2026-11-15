#!/bin/sh
# Installs a launchd job that runs scripts/ai-usage.sh at login and every 30 minutes,
# sending AI usage to the dashboard. API keys come from 1Password via aikey when installed, else .env.
# Log: ~/Library/Logs/koreader-dash-ai-usage.log
#   scripts/install-launchd.sh             install (or reinstall) and run once now
#   scripts/install-launchd.sh --uninstall stop it and remove the job
set -eu
cd "$(dirname "$0")/.."
REPO=$(pwd)
LABEL=com.abharosim.koreader-dash.ai-usage
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# Unloading a job that isn't loaded fails harmlessly.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$PLIST"
    echo "Removed $LABEL"
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
sed -e "s|__REPO__|$REPO|g" -e "s|__HOME__|$HOME|g" \
    "scripts/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart "$DOMAIN/$LABEL"
echo "Installed $LABEL: runs at login and every 30 minutes"
echo "Log: $HOME/Library/Logs/koreader-dash-ai-usage.log"
