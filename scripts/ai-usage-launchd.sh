#!/bin/sh
# What the launchd job runs. If aikey (github.com/abharosim/aikey) is installed and has a
# saved service account token, the API keys come from 1Password through `aikey run`;
# otherwise ai-usage.sh falls back to .env as before. KDASH_URL/KDASH_TOKEN stay in .env.
cd "$(dirname "$0")/.."
AIKEY=$(command -v aikey 2>/dev/null || echo "$HOME/.local/bin/aikey")
# Give up after 2 minutes so a stuck 1Password or Kindle call can't block the next run.
LIMIT=120
if [ -x "$AIKEY" ]; then
    AIKEY_HEADLESS=1 exec perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$AIKEY" run -- /bin/sh scripts/ai-usage.sh "$@"
fi
exec perl -e 'alarm shift; exec @ARGV' "$LIMIT" /bin/sh scripts/ai-usage.sh "$@"
