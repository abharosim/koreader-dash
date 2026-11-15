#!/bin/sh
# What the launchd job runs. If aikey (github.com/abharosim/aikey) is installed and has a
# saved service account token, the API keys come from 1Password through `aikey run`;
# otherwise ai-usage.sh falls back to .env as before. KDASH_URL/KDASH_TOKEN stay in .env.
cd "$(dirname "$0")/.."
AIKEY=$(command -v aikey 2>/dev/null || echo "$HOME/.local/bin/aikey")
if [ -x "$AIKEY" ]; then
    AIKEY_HEADLESS=1 exec "$AIKEY" run -- /bin/sh scripts/ai-usage.sh "$@"
fi
exec /bin/sh scripts/ai-usage.sh "$@"
