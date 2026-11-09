#!/bin/sh
# Pings the Kindle on a timer and records every result, to measure idle reachability.
# Usage: scripts/soak.sh <kindle-ip> [interval-seconds]
# Stop with Ctrl-C. Keep the Mac awake for the run: caffeinate -i scripts/soak.sh <kindle-ip>
set -u
IP="${1:?usage: soak.sh <kindle-ip> [interval-seconds]}"
INTERVAL="${2:-300}"
LOG="soak-$(date +%Y%m%d-%H%M%S).log"
echo "Logging to $LOG"
while :; do
    START=$(date +%s)
    if BODY=$(curl -sS --max-time 10 "http://$IP:8787/ping" 2>&1); then
        RESULT="OK $BODY"
    else
        RESULT="FAIL $BODY"
    fi
    LINE="$(date +%Y-%m-%dT%H:%M:%S) $(( $(date +%s) - START ))s $RESULT"
    echo "$LINE" | tee -a "$LOG"
    sleep "$INTERVAL"
done
