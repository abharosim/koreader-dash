#!/bin/sh
# Posts one Markdown entry to the Kindle dashboard's Audi view.
#
# Usage: scripts/audi-push.sh [--title T] [--id ID] [--ref N] [--source S] FILE.md
#        scripts/audi-push.sh --clear
#        FILE may be - to read stdin.
# A leading --- frontmatter block may set id, ref, title, source, created_at,
# replace_id and action (only "clear"). Flags override the file.
# With no frontmatter, the title is the first "# " heading, else the file name,
# and source defaults to Audi. The id defaults to the file name without .md.
# Exit 0 on 200/201; 1 on any other HTTP status; 2 on bad usage or a bad file;
# 3 if the Kindle can't be reached.
set -u
title="" id="" ref="" source="" created_at="" replace_id="" action=""
title_set=0 id_set=0 ref_set=0 source_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        --title) title=$2; title_set=1; shift 2 ;;
        --id) id=$2; id_set=1; shift 2 ;;
        --ref) ref=$2; ref_set=1; shift 2 ;;
        --source) source=$2; source_set=1; shift 2 ;;
        --clear) action=clear; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        --) shift; break ;;
        -?*) echo "audi-push: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

if [ "$action" = "clear" ] && [ $# -eq 0 ]; then
    file=""
elif [ $# -eq 1 ]; then
    file=$1
else
    echo "audi-push: give exactly one FILE (or -), or --clear" >&2
    exit 2
fi

ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -n "${KDASH_URL:-}" ] && [ -n "${KDASH_TOKEN:-}" ] || {
    echo "audi-push: KDASH_URL and KDASH_TOKEN must be set (in .env)" >&2
    exit 2
}

tmp=$(mktemp)
body=$(mktemp)
fm=$(mktemp)
out=$(mktemp)
json=$(mktemp)
trap 'rm -f "$tmp" "$body" "$fm" "$out" "$json"' EXIT

if [ -n "$file" ]; then
    if [ "$file" = "-" ]; then
        cat > "$tmp"
    else
        [ -f "$file" ] || { echo "audi-push: no such file $file" >&2; exit 2; }
        cat "$file" > "$tmp"
    fi
    # Flat key: value only, from the opening --- through the next ---.
    if ! awk -v bodyfile="$body" '
        function trim(s) {
            gsub(/^[ \t]+/, "", s)
            gsub(/[ \t\r]+$/, "", s)
            return s
        }
        function unquote(s, first, last) {
            s = trim(s)
            first = substr(s, 1, 1)
            last = substr(s, length(s), 1)
            if (length(s) >= 2 && ((first == "\"" && last == "\"") || (first == "'"'"'" && last == "'"'"'"))) {
                s = substr(s, 2, length(s) - 2)
                gsub(/\\"/, "\"", s)
            }
            return s
        }
        BEGIN { state = 0 }
        NR == 1 && $0 ~ /^---[ \t]*\r?$/ { state = 1; next }
        state == 1 && $0 ~ /^---[ \t]*\r?$/ { state = 2; next }
        state == 1 {
            line = $0
            sub(/\r$/, "", line)
            if (match(line, /^[A-Za-z_][A-Za-z0-9_]*:[ \t]*/)) {
                key = substr(line, 1, RLENGTH)
                sub(/:[ \t]*$/, "", key)
                print key "\t" unquote(substr(line, RLENGTH + 1))
            }
            next
        }
        { print > bodyfile }
        END { if (state == 1) exit 2 }
    ' "$tmp" > "$fm"; then
        echo "audi-push: frontmatter has no closing ---" >&2
        exit 2
    fi
    while IFS="$(printf '\t')" read -r key value; do
        [ -n "$key" ] || continue
        case "$key" in
            id) [ "$id_set" -eq 0 ] && id=$value ;;
            ref) [ "$ref_set" -eq 0 ] && ref=$value ;;
            title) [ "$title_set" -eq 0 ] && title=$value ;;
            source) [ "$source_set" -eq 0 ] && source=$value ;;
            created_at) created_at=$value ;;
            replace_id) replace_id=$value ;;
            action) [ -z "$action" ] && action=$value ;;
        esac
    done < "$fm"
fi

if [ -n "$action" ] && [ "$action" != "clear" ]; then
    echo "audi-push: action must be clear" >&2
    exit 2
fi

if [ "$action" != "clear" ]; then
    if [ -z "$title" ]; then
        title=$(sed -n 's/^# \{1,\}//p' "$body" | head -n 1)
        if [ -z "$title" ]; then
            if [ -z "$file" ] || [ "$file" = "-" ]; then
                title="Audi"
            else
                title=$(basename "$file" .md)
            fi
        fi
    fi
    if [ -z "$source" ]; then
        source="Audi"
    fi
    if [ -z "$id" ] && [ -n "$file" ] && [ "$file" != "-" ]; then
        id=$(printf '%s' "$(basename "$file" .md)" | tr -c 'A-Za-z0-9._:-' '_' | cut -c1-64)
    fi
fi

bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }
valid_id() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._:-]{1,64}$'; }

if [ -n "$id" ] && ! valid_id "$id"; then
    echo "audi-push: id must be 1 to 64 of A-Z a-z 0-9 . _ : -" >&2
    exit 2
fi
if [ -n "$replace_id" ] && ! valid_id "$replace_id"; then
    echo "audi-push: replace_id must be 1 to 64 of A-Z a-z 0-9 . _ : -" >&2
    exit 2
fi
if [ -n "$ref" ] && ! printf '%s' "$ref" | grep -Eq '^[1-9][0-9]*$'; then
    echo "audi-push: ref must be a positive integer" >&2
    exit 2
fi
if [ "$(bytes "$title")" -gt 300 ]; then
    echo "audi-push: title is over 300 bytes" >&2
    exit 2
fi
if [ "$(bytes "$source")" -gt 64 ]; then
    echo "audi-push: source is over 64 bytes" >&2
    exit 2
fi
if [ "$(bytes "$created_at")" -gt 64 ]; then
    echo "audi-push: created_at is over 64 bytes" >&2
    exit 2
fi
size=$(wc -c < "$body" | tr -d ' ')
if [ "$size" -gt 262144 ]; then
    echo "audi-push: body is $size bytes; the limit is 256 KB" >&2
    exit 2
fi

jq -n --arg title "$title" --rawfile body "$body" --arg id "$id" --arg source "$source" \
      --arg ref "$ref" --arg created_at "$created_at" --arg replace_id "$replace_id" \
      --arg action "$action" '
    (if $action == "clear" then {action: "clear"} else {body: $body} end)
    + (if $title == "" then {} else {title: $title} end)
    + (if $id == "" then {} else {id: $id} end)
    + (if $source == "" then {} else {source: $source} end)
    + (if $ref == "" then {} else {ref: ($ref | tonumber)} end)
    + (if $created_at == "" then {} else {created_at: $created_at} end)
    + (if $replace_id == "" then {} else {replace_id: $replace_id} end)
' > "$json" || exit 2

code=$(curl -sS -o "$out" -w '%{http_code}' --max-time 15 -X POST "$KDASH_URL/v1/audi" \
    -H "Authorization: Bearer $KDASH_TOKEN" -H "Content-Type: application/json" \
    --data-binary "@$json") || {
    echo "audi-push: Kindle unreachable at $KDASH_URL" >&2
    exit 3
}
case "$code" in
    200|201) echo "audi-push: $code $(cat "$out")"; exit 0 ;;
    *) echo "audi-push: HTTP $code $(cat "$out")" >&2; exit 1 ;;
esac
