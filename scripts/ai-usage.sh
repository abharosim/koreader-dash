#!/bin/sh
# Sends AI usage to the dashboard's usage tiles (Grok, Claude, DeepSeek, Gemini).
# Fetches what has an API, takes the rest from flags, and sends one PUT /v1/state.
# Only providers with new data are sent, so the others keep their last values.
#
# Fetched automatically when the variable is set (in the environment or .env):
#   DEEPSEEK_API_KEY       DeepSeek balance (GET api.deepseek.com/user/balance)
#   XAI_MANAGEMENT_KEY     xAI API prepaid credit balance, with XAI_TEAM_ID
#                          (GET management-api.x.ai/v1/billing/teams/{team}/prepaid/balance)
#   CLAUDE_OAUTH_TOKEN     Claude plan usage (5-hour and weekly) from the endpoint Claude Code's
#                          /usage uses. Undocumented, so it may break. Or set
#                          KDASH_CLAUDE_FROM_KEYCHAIN=1 to read Claude Code's own login from the
#                          macOS Keychain each run instead of storing a token.
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
# <provider> is grok, anthropic, deepseek or gemini. Flags override fetched values.
# --dry-run prints the JSON instead of sending it.
# --allow-empty exits 0 when there's nothing to send (for the scheduled job, which runs with no flags).
#
# Examples:
#   scripts/ai-usage.sh                                   # fetch everything configured
#   scripts/ai-usage.sh --grok-pct 17.4 --grok-resets 2026-11-20T23:24:00Z
#   scripts/ai-usage.sh --gemini-spent 3.20 --gemini-detail "Nov, API"
# Run it from cron or launchd (e.g. every 15 minutes) to keep the tiles current.
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

fetch_grok_api() {
    [ -n "${XAI_MANAGEMENT_KEY:-}" ] && [ -n "${XAI_TEAM_ID:-}" ] || return 0
    response=$(curl -sf --max-time 10 \
        "https://management-api.x.ai/v1/billing/teams/$XAI_TEAM_ID/prepaid/balance" \
        -H "Authorization: Bearer $XAI_MANAGEMENT_KEY") \
        || { warn "xAI request failed"; return 0; }
    # total.val is USD cents; purchases are negative, so the balance is its negation.
    cents=$(printf '%s' "$response" | jq -r '.total.val // empty' 2>/dev/null)
    [ -n "$cents" ] || { warn "xAI response had no balance"; return 0; }
    patch=$(printf '%s' "$patch" | jq -c --arg c "$cents" --argjson t "$now" \
        '.grok = { balance: (($c | tonumber) / -100), currency: "USD",
                   detail: "API credits", updated_at: $t }')
}

fetch_anthropic() {
    token="${CLAUDE_OAUTH_TOKEN:-}"
    if [ -z "$token" ] && [ "${KDASH_CLAUDE_FROM_KEYCHAIN:-}" = "1" ]; then
        token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
            | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    [ -n "$token" ] || return 0
    response=$(curl -sf --max-time 10 https://api.anthropic.com/api/oauth/usage \
        -H "Authorization: Bearer $token" -H "anthropic-beta: oauth-2025-04-20" \
        -H "Accept: application/json") \
        || { warn "Claude usage request failed (token expired? the endpoint is undocumented)"; return 0; }
    info=$(printf '%s' "$response" | jq -c '
        def epoch: if . == null then null else sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 end;
        select(.seven_day != null)
        | { used_pct: .seven_day.utilization,
            resets_at: (.seven_day.resets_at | epoch),
            headline: ((.seven_day.utilization | floor | tostring) + "% · 5h "
                       + ((.five_hour.utilization // 0) | floor | tostring) + "%"),
            detail: "week" }
        | with_entries(select(.value != null))' 2>/dev/null)
    [ -n "$info" ] || { warn "Claude usage response had no weekly figure"; return 0; }
    patch=$(printf '%s' "$patch" | jq -c --argjson i "$info" --argjson t "$now" \
        '.anthropic = ($i + {updated_at: $t})')
}

fetch_deepseek
fetch_grok_api
fetch_anthropic

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1; shift; continue ;;
        --allow-empty) allow_empty=1; shift; continue ;;
        --grok-*|--anthropic-*|--deepseek-*|--gemini-*) ;;
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
