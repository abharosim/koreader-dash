# Claude usage login owned by koreader-dash (sourced by ai-usage.sh; created by scripts/claude-login.py).
# Its tokens live in their own Keychain item, so refreshing rotates only koreader-dash's refresh token.
# Claude Code's own item ("Claude Code-credentials") is only ever read, never written.
CLAUDE_KC_SERVICE=koreader-dash-claude-oauth
CLAUDE_KC_ACCOUNT=oauth
CLAUDE_CLIENT_ID=9d1c250a-e61b-44d9-88ed-5944d1962f5e
CLAUDE_TOKEN_URL=https://console.anthropic.com/v1/oauth/token
CLAUDE_USAGE_URL=https://api.anthropic.com/api/oauth/usage
CLAUDE_STATE_DIR="$HOME/Library/Caches/koreader-dash"

# User-Agent claude-code/<newest installed Claude Code version>. Reads the install folder; never runs claude.
claude_user_agent() {
    v=$(ls "$HOME/.local/share/claude/versions" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    printf 'claude-code/%s' "${v:-2.1.0}"
}

# Prints the saved login JSON {access_token, refresh_token, expires_at}, or nothing.
claude_oauth_load() {
    security find-generic-password -s "$CLAUDE_KC_SERVICE" -a "$CLAUDE_KC_ACCOUNT" -w 2>/dev/null \
        | base64 -D 2>/dev/null
}

# Saves login JSON ($1). The value goes to security on stdin, never in process arguments.
claude_oauth_save() {
    b=$(printf '%s' "$1" | base64 | tr -d '\n')
    printf 'add-generic-password -U -s %s -a %s -l "koreader-dash Claude usage login" -w %s\n' \
        "$CLAUDE_KC_SERVICE" "$CLAUDE_KC_ACCOUNT" "$b" | security -i >/dev/null 2>&1
}

# Serialises refreshes: a rotated refresh token is single-use, so two refreshes at once would kill the login.
claude_lock() {
    mkdir -p "$CLAUDE_STATE_DIR"
    lock="$CLAUDE_STATE_DIR/claude.lock"
    if mkdir "$lock" 2>/dev/null; then return 0; fi
    # A lock left by a killed run (over 3 minutes old) is cleared.
    if [ $(( $(date +%s) - $(stat -f %m "$lock" 2>/dev/null || echo 0) )) -gt 180 ]; then
        rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null && return 0
    fi
    return 1
}
claude_unlock() { rmdir "$CLAUDE_STATE_DIR/claude.lock" 2>/dev/null || true; }

# Refreshes the saved login ($1 = current JSON). Prints the new JSON after saving it.
# Returns 0 ok, 2 dead grant (needs scripts/claude-login.py), 1 other failure.
claude_oauth_refresh() {
    rt=$(printf '%s' "$1" | jq -r '.refresh_token // empty')
    [ -n "$rt" ] || return 2
    out=$(mktemp)
    code=$(jq -nc --arg r "$rt" --arg c "$CLAUDE_CLIENT_ID" \
            '{grant_type: "refresh_token", refresh_token: $r, client_id: $c}' \
        | curl -s -o "$out" -w '%{http_code}' --max-time 15 -X POST "$CLAUDE_TOKEN_URL" \
            -H "Content-Type: application/json" -H "User-Agent: $(claude_user_agent)" --data-binary @-) || code=000
    if [ "$code" != 200 ]; then
        err=$(jq -r '.error // empty' "$out" 2>/dev/null); rm -f "$out"
        case "$code:$err" in 400:invalid_grant|401:*|400:invalid_request) return 2 ;; esac
        return 1
    fi
    new=$(jq -c --arg old "$rt" --argjson t "$(date +%s)" '
        select(.access_token != null and .access_token != "")
        | { access_token, refresh_token: (.refresh_token // $old),
            expires_at: ($t + (.expires_in // 3600)) }' "$out" 2>/dev/null)
    rm -f "$out"
    [ -n "$new" ] || return 1
    claude_oauth_save "$new" || return 1
    printf '%s' "$new"
}

# GET usage with token $1 into file $2, headers into $3. Prints the HTTP status. The token goes to curl on stdin.
claude_usage_get() {
    printf 'header = "Authorization: Bearer %s"\n' "$1" \
        | curl -s -K - -o "$2" -D "$3" -w '%{http_code}' --max-time 10 "$CLAUDE_USAGE_URL" \
            -H "anthropic-beta: oauth-2025-04-20" -H "Accept: application/json" \
            -H "User-Agent: $(claude_user_agent)" || printf '000'
}
