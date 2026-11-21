#!/bin/sh
# Checks audi-push.sh frontmatter parsing and the Audi outbox, without a Kindle.
# A fake curl records the JSON. Run from scripts/test.sh.
set -u
cd "$(dirname "$0")/.."
ROOT=$(pwd)
fail=0
pass=0

ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; echo "      $2"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/curl" << 'EOF'
#!/bin/sh
out=""
data=""
: "${FAKE_CURL_PAYLOAD:?}"
: "${FAKE_CURL_COUNT:?}"
count=$(cat "$FAKE_CURL_COUNT")
printf '%s' "$((count + 1))" > "$FAKE_CURL_COUNT"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        --data-binary) data=$2; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "$data" ]; then
    cp "${data#@}" "$FAKE_CURL_PAYLOAD"
fi
mode=${FAKE_CURL_MODE:-201}
if [ "$mode" = "down" ]; then
    echo "curl: connection refused" >&2
    exit 7
fi
if [ -n "$out" ]; then
    if [ "$mode" = "400" ]; then
        echo '{"error":"bad_field"}' > "$out"
    else
        echo '{"id":"x","ref":12,"created":true,"updated":false}' > "$out"
    fi
fi
printf '%s' "$mode"
exit 0
EOF
chmod +x "$WORK/bin/curl"

export PATH="$WORK/bin:$PATH"
export KDASH_URL="http://127.0.0.1:8787"
export KDASH_TOKEN="test-token-not-a-secret"
export FAKE_CURL_PAYLOAD="$WORK/payload.json"
export FAKE_CURL_COUNT="$WORK/count"
export FAKE_CURL_MODE=201
printf '%s' 0 > "$FAKE_CURL_COUNT"

payload() { jq -e "$@" "$FAKE_CURL_PAYLOAD" >/dev/null 2>"$WORK/jq.err"; }
calls() { cat "$FAKE_CURL_COUNT"; }

run_push() {
    FAKE_CURL_MODE=${1:-201}
    shift
    "$ROOT/scripts/audi-push.sh" "$@" >"$WORK/out" 2>"$WORK/err"
}

# 1. Frontmatter fields, and the body is the Markdown under the closing ---.
note="$WORK/audi-20261120-191200.md"
cat > "$note" << 'EOF'
---
id: audi-20261120-191200
ref: 12
title: "DeepSeek 审查结果"
source: DeepSeek
created_at: 2026-11-20T19:12:00-05:00
replace_id: audi-old
---

## 摘要

`fib.py` stays in the body.
EOF
if run_push 201 "$note" && payload \
    '.id == "audi-20261120-191200" and .ref == 12 and .title == "DeepSeek 审查结果" and .source == "DeepSeek" and .created_at == "2026-11-20T19:12:00-05:00" and .replace_id == "audi-old" and (.body | contains("## 摘要")) and (.body | contains("fib.py")) and (.body | contains("replace_id") | not) and (.body | contains("source: DeepSeek") | not)'; then
    ok "frontmatter fields are posted and the body excludes them"
else
    bad "frontmatter fields are posted and the body excludes them" "$(cat "$WORK/err"; echo; cat "$FAKE_CURL_PAYLOAD" 2>/dev/null; cat "$WORK/jq.err" 2>/dev/null)"
fi

# 2. No frontmatter: heading, filename id, default source.
plain="$WORK/my file!.md"
printf '%s\n' "# Hello title" "" "plain body" > "$plain"
if run_push 201 "$plain" && payload '.id == "my_file_" and .title == "Hello title" and .source == "Audi" and (.body | contains("plain body")) and .ref == null'; then
    ok "no frontmatter uses the heading, filename id and source Audi"
else
    bad "no frontmatter uses the heading, filename id and source Audi" "$(cat "$FAKE_CURL_PAYLOAD" 2>/dev/null)"
fi

# 3. Flags override frontmatter; created_at from the file remains.
if run_push 201 --title "Flag title" --id flag-id --ref 9 --source FlagSource "$note" && payload \
    '.id == "flag-id" and .ref == 9 and .title == "Flag title" and .source == "FlagSource" and .created_at == "2026-11-20T19:12:00-05:00"'; then
    ok "command flags override frontmatter"
else
    bad "command flags override frontmatter" "$(cat "$FAKE_CURL_PAYLOAD" 2>/dev/null)"
fi

# 4. Stdin.
if printf '%s\n' "---" "id: from-stdin" "title: From stdin" "---" "stdin body" | run_push 201 - && payload \
    '.id == "from-stdin" and .title == "From stdin" and (.body | contains("stdin body")) and .source == "Audi"'; then
    ok "stdin with frontmatter is accepted"
else
    bad "stdin with frontmatter is accepted" "$(cat "$WORK/err"; cat "$FAKE_CURL_PAYLOAD" 2>/dev/null)"
fi

# 5. --clear posts the clear action and no body.
if run_push 201 --clear && payload '.action == "clear" and .body == null and .title == null'; then
    ok "--clear posts action clear"
else
    bad "--clear posts action clear" "$(cat "$FAKE_CURL_PAYLOAD" 2>/dev/null; cat "$WORK/err")"
fi

# 6. A clear file is action clear, not a new titled entry.
clearf="$WORK/clear.md"
printf '%s\n' "---" "id: audi-clear" "action: clear" "---" > "$clearf"
if run_push 201 "$clearf" && payload '.action == "clear" and .id == "audi-clear"'; then
    ok "action clear in frontmatter is posted"
else
    bad "action clear in frontmatter is posted" "$(cat "$FAKE_CURL_PAYLOAD" 2>/dev/null)"
fi

# 7. Bad ref, missing file, oversized body: exit 2, and curl is not called.
before=$(calls)
badref="$WORK/bad-ref.md"
printf '%s\n' "---" "ref: nope" "title: T" "---" "x" > "$badref"
run_push 201 "$badref"
rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls)" -eq "$before" ]; then
    ok "a non-numeric ref is a usage error"
else
    bad "a non-numeric ref is a usage error" "exit $rc calls $(calls)"
fi
before=$(calls)
run_push 201 "$WORK/missing.md"
rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls)" -eq "$before" ]; then
    ok "a missing file is a usage error"
else
    bad "a missing file is a usage error" "exit $rc"
fi

# 8. Id from a long messy filename is sanitized and cut to 64.
long=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70)
longf="$WORK/${long}!.md"
printf '%s\n' "just text" > "$longf"
want=$(printf '%s' "${long}_" | cut -c1-64)
base=$(basename "$longf" .md)
if run_push 201 "$longf" && payload --arg id "$want" --arg title "$base" \
    '.id == $id and (.id | length) == 64 and .title == $title and (.body | contains("just text"))'; then
    ok "filename id is sanitized and cut to 64"
else
    bad "filename id is sanitized and cut to 64" "want $want got $(jq -r .id "$FAKE_CURL_PAYLOAD" 2>/dev/null) title $(jq -r .title "$FAKE_CURL_PAYLOAD" 2>/dev/null)"
fi

# 9. Unreachable and HTTP errors.
if run_push down "$plain"; then
    bad "unreachable Kindle exits 3" "exit 0"
else
    rc=$?
    if [ "$rc" -eq 3 ]; then
        ok "unreachable Kindle exits 3"
    else
        bad "unreachable Kindle exits 3" "exit $rc $(cat "$WORK/err")"
    fi
fi
if run_push 400 "$plain"; then
    bad "HTTP errors exit 1" "exit 0"
else
    rc=$?
    if [ "$rc" -eq 1 ]; then
        ok "HTTP errors exit 1"
    else
        bad "HTTP errors exit 1" "exit $rc $(cat "$WORK/err")"
    fi
fi

# 10. Drop folder: success, skip a fresh file, retry when down, failed otherwise.
export KDASH_AUDI="$WORK/kdash-audi"
mkdir -p "$KDASH_AUDI"
cat > "$KDASH_AUDI/box-1.md" << 'EOF'
---
id: box-1
ref: 3
title: From the drop folder
source: audi28
---
Dropped body
EOF
printf '%s\n' "# Still writing" > "$KDASH_AUDI/fresh.md"
perl -e 'utime time-30, time-30, $ARGV[0]' "$KDASH_AUDI/box-1.md"
FAKE_CURL_MODE=201
log=$("$ROOT/scripts/audi-outbox-send.sh" 2>&1)
if [ -f "$KDASH_AUDI/sent/box-1.md" ] && [ -f "$KDASH_AUDI/fresh.md" ] && printf '%s' "$log" | grep -q "audi-outbox:.*sent box-1"; then
    ok "drop folder sends an old file and skips one just written"
else
    bad "drop folder sends an old file and skips one just written" "$log"
fi

cat > "$KDASH_AUDI/retry-me.md" << 'EOF'
---
id: retry-me
title: Retry
---
later
EOF
perl -e 'utime time-30, time-30, $ARGV[0]' "$KDASH_AUDI/retry-me.md"
FAKE_CURL_MODE=down
log=$("$ROOT/scripts/audi-outbox-send.sh" 2>&1)
if [ -f "$KDASH_AUDI/retry-me.md" ] && printf '%s' "$log" | grep -q "audi-outbox:.*will retry retry-me"; then
    ok "an unreachable Kindle leaves the drop file in place"
else
    bad "an unreachable Kindle leaves the drop file in place" "$log"
fi

cat > "$KDASH_AUDI/bad.md" << 'EOF'
---
ref: nope
title: Bad
---
x
EOF
perl -e 'utime time-30, time-30, $ARGV[0]' "$KDASH_AUDI/bad.md"
FAKE_CURL_MODE=201
log=$("$ROOT/scripts/audi-outbox-send.sh" 2>&1)
if [ -f "$KDASH_AUDI/failed/bad.md" ] && printf '%s' "$log" | grep -q "audi-outbox:.*FAILED bad"; then
    ok "a bad drop file is moved to failed"
else
    bad "a bad drop file is moved to failed" "$log"
fi

# 11. The briefing outbox job is what launchd runs, so it must deliver Audi too.
export KDASH_OUTBOX="$WORK/kdash-outbox"
mkdir -p "$KDASH_OUTBOX/sent" "$KDASH_OUTBOX/failed"
cat > "$KDASH_AUDI/via-job.md" << 'EOF'
---
id: via-job
title: Via the job
source: DeepSeek
---
through outbox-send
EOF
perl -e 'utime time-30, time-30, $ARGV[0]' "$KDASH_AUDI/via-job.md"
FAKE_CURL_MODE=201
log=$("$ROOT/scripts/outbox-send.sh" 2>&1)
if [ -f "$KDASH_AUDI/sent/via-job.md" ] && printf '%s' "$log" | grep -q "audi-outbox:.*sent via-job"; then
    ok "the existing outbox job also sends ~/kdash-audi"
else
    bad "the existing outbox job also sends ~/kdash-audi" "$log"
fi

if grep -q "kdash-audi" "$ROOT/scripts/launchd/com.abharosim.koreader-dash.outbox.plist" \
    && grep -q "kdash-audi" "$ROOT/scripts/install-outbox.sh"; then
    ok "launchd watches ~/kdash-audi and the installer creates it"
else
    bad "launchd watches ~/kdash-audi and the installer creates it" "plist or installer missing kdash-audi"
fi

echo
echo "$pass passed, $fail failed"
exit "$fail"
