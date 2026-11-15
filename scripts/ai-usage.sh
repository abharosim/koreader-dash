#!/bin/sh
# Sends AI usage to the dashboard's usage tiles (Grok Bot, Claude, DeepSeek, xAI API).
# Fetches what has an API, takes the rest from flags, and sends one PUT /v1/state.
# Only providers with new data are sent, so the others keep their last values.
#
# Fetched automatically when the variable is set (in the environment or .env):
#   DEEPSEEK_API_KEY       DeepSeek balance (GET api.deepseek.com/user/balance)
#   XAI_MANAGEMENT_KEY     xAI API spend this month and prepaid balance (Billing read-only key;
#                          XAI_TEAM_ID optional, read from the key otherwise)
#                          (GET management-api.x.ai/v1/billing/teams/{team}/prepaid/balance)
#   CLAUDE_OAUTH_TOKEN     (or CLAUDE_CODE_OAUTH_TOKEN) Claude plan usage (5-hour and weekly) from the endpoint Claude Code's
#                          /usage uses. Undocumented, so it may break. Or set
#                          KDASH_CLAUDE_FROM_KEYCHAIN=1 (the launchd job) to use koreader-dash's own Claude
#                          login (scripts/claude-login.py, Keychain item koreader-dash-claude-oauth), which it
#                          refreshes itself; without that login it reads Claude Code's login read-only while valid.
#                          When the fetch fails, the tile keeps its numbers and is marked 已过期 (stale).
# Gemini and Grok plans have no usage API, so pass them by hand:
#   --<provider>-pct N        percent of the plan used, 0-100
#   --<provider>-resets T     when the plan resets: Unix seconds or 2026-11-20T23:24:00Z
#   --<provider>-spent N      money spent this period;  --<provider>-currency USD
#   --<provider>-balance N    money left
#   --<provider>-detail TEXT  one short line, e.g. "Tier 1"; it shares a line with the reset time
#   --<provider>-label TEXT   tile title instead of the default
#   --<provider>-headline TEXT  the big line, instead of one made from the numbers
#   (an empty TEXT removes that field)
#   --<provider>-clear        remove that tile's data (shows "No data yet")
# <provider> is grok, anthropic, deepseek or xai. Flags override fetched values.
# --dry-run prints the JSON instead of sending it.
# --allow-empty exits 0 when there's nothing to send (for the scheduled job, which runs with no flags).
#
# Examples:
#   scripts/ai-usage.sh                                   # fetch everything configured
#   scripts/ai-usage.sh --grok-pct 17.4 --grok-resets 2026-11-20T23:24:00Z
#   scripts/ai-usage.sh --xai-spent 3.20 --xai-detail "Nov"
# Run it from cron or launchd (scripts/install-launchd.sh runs it every 30 minutes) to keep the tiles current.
set -u
cd "$(dirname "$0")/.."
[ -f .env ] && . ./.env

now=$(date +%s)
patch='{}'
dry_run=0
allow_empty=0

# Adds one field: set_field provider field json_value
set_field() {
    patch=$(printf '%s' "$patch" | jq -c --arg p "$1" --arg f "$2" --argjson v "$3" \
        '.[$p] = ((.[$p] // {}) + {($f): $v})')
}

# Unix seconds from Unix seconds or an ISO 8601 UTC time (fractions and +00:00 allowed).
to_epoch() {
    case "$1" in
        *[!0-9]*) jq -rn --arg t "$1" \
            '$t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601' 2>/dev/null ;;
        *) printf '%s' "$1" ;;
    esac
}

warn() { echo "ai-usage: $*" >&2; }

fetch_deepseek() {
    [ -n "${DEEPSEEK_API_KEY:-}" ] || return 0
    response=$(curl -sf --max-time 10 https://api.deepseek.com/user/balance \
        -H "Authorization: Bearer $DEEPSEEK_API_KEY" -H "Accept: application/json") \
        || { warn "DeepSeek request failed"; return 0; }
    # Prefers USD when the account holds both currencies.
    info=$(printf '%s' "$response" | jq -c '
        (.balance_infos // []) as $all
        | (([$all[] | select(.currency == "USD")] + $all)[0]) // empty
        | { balance: (.total_balance | tonumber), currency: .currency, detail: null }' 2>/dev/null)
    [ -n "$info" ] || { warn "DeepSeek response had no balance"; return 0; }
    available=$(printf '%s' "$response" | jq -r '.is_available')
    [ "$available" = "false" ] && info=$(printf '%s' "$info" | jq -c '.detail = "out of balance"')
    patch=$(printf '%s' "$patch" | jq -c --argjson i "$info" --argjson t "$now" \
        '.deepseek = ($i + {updated_at: $t})')
}

fetch_xai() {
    # xAI API (not Grok Bot): needs a management key with Billing read-only.
    [ -n "${XAI_MANAGEMENT_KEY:-}" ] || return 0
    auth="Authorization: Bearer $XAI_MANAGEMENT_KEY"
    team="${XAI_TEAM_ID:-}"
    [ -n "$team" ] || team=$(curl -sf --max-time 10 https://management-api.x.ai/auth/management-keys/validation \
        -H "$auth" | jq -r '.scopeId // .teamId // empty' 2>/dev/null)
    [ -n "$team" ] || { warn "xAI: couldn't find the team id (set XAI_TEAM_ID)"; return 0; }
    base="https://management-api.x.ai/v1/billing/teams/$team"
    # total.val is USD cents; purchases are negative, so the balance is its negation.
    cents=$(curl -sf --max-time 10 "$base/prepaid/balance" -H "$auth" | jq -r '.total.val // empty' 2>/dev/null)
    # Spend so far this calendar month, in dollars.
    start=$(date '+%Y-%m-01 00:00:00')
    end=$(date -v+1m '+%Y-%m-01 00:00:00' 2>/dev/null || date -d "$(date +%Y-%m-01) +1 month" '+%Y-%m-01 00:00:00')
    body=$(jq -nc --arg s "$start" --arg e "$end" --arg z "${TZ:-America/New_York}" \
        '{analyticsRequest: {timeRange: {startTime: $s, endTime: $e, timezone: $z}, timeUnit: "TIME_UNIT_NONE",
          values: [{name: "usd", aggregation: "AGGREGATION_SUM"}], groupBy: [], filters: []}}')
    spent=$(curl -sf --max-time 15 -X POST "$base/usage" -H "$auth" -H "Content-Type: application/json" -d "$body" \
        | jq -r '[.timeSeries[]?.dataPoints[]?.values[0] // 0] | add // 0' 2>/dev/null)
    [ -n "$cents$spent" ] || { warn "xAI requests failed"; return 0; }
    detail=$(date +%b)
    [ -n "$cents" ] && detail="$detail · bal \$$(awk -v c="$cents" 'BEGIN { printf "%.2f", -c / 100 + 0 }')"
    patch=$(printf '%s' "$patch" | jq -c --arg s "${spent:-0}" --arg d "$detail" --argjson t "$now" \
        '.xai = { spent: ($s | tonumber), currency: "USD", detail: $d, updated_at: $t }')
}

# Keeps the last Claude numbers on the tile but marks them stale ("已过期" plus the last update time).
# expires_at 1 is a fixed past time, so repeat failures don't count as changes.
mark_claude_stale() {
    warn "Claude: $1; tile marked stale"
    patch=$(printf '%s' "$patch" | jq -c '.anthropic = {expires_at: 1, stale_label: "已过期"}')
}

fetch_anthropic() {
    token="" src=""
    use_kc=0; [ "${KDASH_CLAUDE_FROM_KEYCHAIN:-}" = "1" ] && use_kc=1
    if [ "$use_kc" = 1 ]; then
        . scripts/lib/claude-oauth.sh
        retry_file="$CLAUDE_STATE_DIR/claude-retry-after"
        if [ -f "$retry_file" ] && [ "$now" -lt "$(cat "$retry_file" 2>/dev/null || echo 0)" ]; then
            warn "Claude: rate limited until $(date -r "$(cat "$retry_file")" '+%H:%M'); skipped"
            return 0
        fi
        claude_lock || { warn "Claude: another run is refreshing the login; skipped"; return 0; }
        creds=$(claude_oauth_load)
        if [ -n "$creds" ]; then
            src=own
            exp=$(printf '%s' "$creds" | jq -r '.expires_at // 0')
            if [ $((exp - now)) -lt 300 ]; then
                new=$(claude_oauth_refresh "$creds"); rc=$?
                case $rc in
                    0) creds=$new ;;
                    2) claude_unlock; mark_claude_stale "koreader-dash's Claude login has ended; run scripts/claude-login.py"; return 0 ;;
                    *) claude_unlock; mark_claude_stale "token refresh failed (network?)"; return 0 ;;
                esac
            fi
            token=$(printf '%s' "$creds" | jq -r '.access_token // empty')
        else
            # Fallback: read Claude Code's own login, read-only, and only while it hasn't expired.
            # It is never refreshed or written here: its refresh token is single-use and rotating.
            cc=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)
            cc_exp=$(printf '%s' "$cc" | jq -r '(.claudeAiOauth.expiresAt // 0) / 1000 | floor' 2>/dev/null)
            if [ "${cc_exp:-0}" -gt "$now" ]; then
                token=$(printf '%s' "$cc" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
                src=claude-code
            fi
        fi
    fi
    # Otherwise accept the name Claude Code uses too, and an OAuth token (sk-ant-oat...) saved as ANTHROPIC_API_KEY.
    [ -n "$token" ] || { token="${CLAUDE_OAUTH_TOKEN:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"; [ -n "$token" ] && src=env; }
    if [ -z "$token" ]; then
        case "${ANTHROPIC_API_KEY:-}" in sk-ant-oat*) token=$ANTHROPIC_API_KEY; src=env ;; esac
    fi
    if [ -z "$token" ]; then
        [ "$use_kc" = 1 ] && { claude_unlock; mark_claude_stale "no valid login (run scripts/claude-login.py)"; }
        return 0
    fi

    body_file=$(mktemp); head_file=$(mktemp)
    if [ "$use_kc" = 1 ]; then
        status=$(claude_usage_get "$token" "$body_file" "$head_file")
        # One forced refresh if the server rejects a token we thought was still valid.
        if [ "$status" = 401 ] && [ "$src" = own ]; then
            new=$(claude_oauth_refresh "$creds") && {
                creds=$new; token=$(printf '%s' "$creds" | jq -r '.access_token')
                status=$(claude_usage_get "$token" "$body_file" "$head_file"); }
        fi
        claude_unlock
    else
        status=$(curl -s -o "$body_file" -D "$head_file" -w '%{http_code}' --max-time 10 "https://api.anthropic.com/api/oauth/usage" \
            -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" -H "Accept: application/json") || status=000
    fi
    response=$(cat "$body_file"); retry=$(tr -d '\r' < "$head_file" | awk -F': *' 'tolower($1)=="retry-after" {print $2}' | tail -n 1)
    rm -f "$body_file" "$head_file"
    case "$status" in
        200) ;;
        429)
            # Honour Retry-After; when it's missing or 0, wait 10 minutes. At most an hour.
            case "$retry" in ''|*[!0-9]*) retry=0 ;; esac
            [ "$retry" -ge 600 ] || retry=600; [ "$retry" -le 3600 ] || retry=3600
            [ "$use_kc" = 1 ] && echo $((now + retry)) > "$retry_file"
            warn "Claude: rate limited (429); next try after $((retry / 60)) minutes"
            return 0 ;;
        *)
            if [ "$use_kc" = 1 ]; then mark_claude_stale "usage request failed (HTTP $status, $src login)"
            else warn "Claude usage request failed (HTTP $status)"; fi
            return 0 ;;
    esac
    info=$(printf '%s' "$response" | jq -c '
        def epoch: if . == null then null else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end;
        select(.seven_day != null)
        | { used_pct: .seven_day.utilization,
            resets_at: (.seven_day.resets_at | epoch),
            headline: ((.seven_day.utilization | floor | tostring) + "% · 5h "
                       + ((.five_hour.utilization // 0) | floor | tostring) + "%"),
            detail: "W" }
        | with_entries(select(.value != null))' 2>/dev/null)
    [ -n "$info" ] || { [ "$use_kc" = 1 ] && mark_claude_stale "response had no weekly figure" || warn "Claude usage response had no weekly figure"; return 0; }
    # null clears an earlier stale mark (PUT /v1/state is a merge patch).
    patch=$(printf '%s' "$patch" | jq -c --argjson i "$info" --argjson t "$now" \
        '.anthropic = ($i + {updated_at: $t, expires_at: null, stale_label: null})')
}

fetch_deepseek
fetch_xai
fetch_anthropic

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1; shift; continue ;;
        --allow-empty) allow_empty=1; shift; continue ;;
        --grok-*|--anthropic-*|--deepseek-*|--xai-*|--gemini-*) ;;
        *) warn "unknown option: $1"; exit 2 ;;
    esac
    option=${1#--}
    provider=${option%%-*}
    field=${option#*-}
    if [ "$field" = "clear" ]; then
        patch=$(printf '%s' "$patch" | jq -c --arg p "$provider" '.[$p] = null')
        shift
        continue
    fi
    [ $# -ge 2 ] || { warn "$1 needs a value"; exit 2; }
    value=$2
    shift 2
    case "$field" in
        pct|spent|balance)
            case "$value" in ''|*[!0-9.]*|*.*.*) warn "--$option needs a number"; exit 2 ;; esac
            [ "$field" = pct ] && field=used_pct
            set_field "$provider" "$field" "$value" ;;
        resets)
            epoch=$(to_epoch "$value")
            [ -n "$epoch" ] || { warn "--$option needs Unix seconds or 2026-11-20T23:24:00Z"; exit 2; }
            set_field "$provider" resets_at "$epoch" ;;
        detail|label|currency|headline)
            # An empty value removes the field.
            set_field "$provider" "$field" "$(jq -n --arg v "$value" 'if $v == "" then null else $v end')" ;;
        *) warn "unknown option: --$option"; exit 2 ;;
    esac
    # A hand-set value counts as fresh too.
    patch=$(printf '%s' "$patch" | jq -c --arg p "$provider" --argjson t "$now" \
        'if .[$p] != null then .[$p].updated_at = $t else . end')
done

if [ "$patch" = '{}' ] && [ "$allow_empty" = 1 ]; then
    echo "ai-usage: $(date '+%Y-%m-%d %H:%M:%S') nothing to send (no API keys set); tiles left as they are"
    exit 0
fi
if [ "$patch" = '{}' ]; then
    warn "nothing to send: set DEEPSEEK_API_KEY, CLAUDE_OAUTH_TOKEN or XAI_MANAGEMENT_KEY, or pass values (see the top of this file)"
    exit 1
fi
body=$(printf '%s' "$patch" | jq -c '{usage: .}')
if [ "$dry_run" = 1 ]; then
    printf '%s\n' "$body" | jq .
    exit 0
fi
[ -n "${KDASH_URL:-}" ] && [ -n "${KDASH_TOKEN:-}" ] || { warn "KDASH_URL and KDASH_TOKEN must be set (in .env)"; exit 1; }
printf 'ai-usage: %s sending %s: ' "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$patch" | jq -r 'keys | join(", ")')"
curl -sS --max-time 10 -X PUT "$KDASH_URL/v1/state" \
    -H "Authorization: Bearer $KDASH_TOKEN" -H "Content-Type: application/json" \
    --data-binary "$body"
echo
