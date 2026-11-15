#!/usr/bin/env bash
# Phase 3: multi-rule joint-decision verification (D6, independent of dims.sh, separation of concerns)
#
# Usage: ./bench/rules.sh
#
# Scenarios:
#   ① All-or-nothing core: pre-set one bucket empty and one non-empty → 429 and both buckets' tokens unchanged (spec core scenario)
#   ② All-sufficient pass: each bucket decremented by exactly 1
#   ③ Group fingerprint re-buckets: change only one rule's limit → the whole group's fingerprint segment changes, old buckets no longer hit
#   ④ Response semantics: passing-request header bottleneck values / 429 body rule field / Retry-After cap
#   ⑤ Three classes of bad config 400 + valid rules 201
#
# Notes: each scenario has its own namespace; preset buckets use ts=now+30 to freeze refill (zero refill within the window,
#   exact assertion values); after the run the last config round stays in the runtime (later scripts overwrite it wholesale).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PASS=0
FAIL=0
report() { # report <true|false> <description>
    if [ "$1" = "true" ]; then
        ok "PASS: $2"
        PASS=$((PASS + 1))
    else
        warn "FAIL: $2"
        FAIL=$((FAIL + 1))
    fi
}
fresh() {
    docker compose exec -T redis redis-cli FLUSHDB >/dev/null
}
code() { # code <url> [curl args...]
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' "$@" "$url"
}
dexec() { # unified entry point for commands inside the redis container
    docker compose exec -T redis "$@"
}
# Generate a rules-mode declarative config (common.sh's kong_config_json does not support rules; specific to this script)
# Usage: kong_rules_config_json <ns> <rules_json> [batch] [top_limit]
kong_rules_config_json() {
    local ns="$1" rules="$2" batch="${3:-0}" limit="${4:-100}"
    cat <<EOF
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"echo-route","paths":["/echo"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{
   "limit":${limit},"window":3600,"batch":${batch},
   "namespace":"${ns}","fault_tolerant":false,
   "rules":${rules},
   "redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]}]}]}
EOF
}
# Get bucket keys within the group: group_bucket <ns> <r1|r2>
group_bucket() {
    dexec sh -c "redis-cli --scan --pattern 'kong:rl:{${1}:*' | grep ':${2}:' | head -1"
}
# Preset bucket (ts=now+30 freezes refill): preset_bucket <key> <tokens>
preset_bucket() {
    local ts
    ts=$(( $(date +%s) + 30 ))
    dexec redis-cli hset "$1" tokens "$2" ts "$ts" >/dev/null
}
bucket_tokens() { # bucket_tokens <key>
    dexec redis-cli hget "$1" tokens
}

echo "===== Scenario 1/5: all-or-nothing core (one empty, one non-empty ⇒ 429 and both buckets unchanged) ====="
NS="rules-allornone"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
# Send one request first so both buckets land (new buckets = full), and grab the real group keys
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"
R2_KEY="$(group_bucket "$NS" r2)"
if [ -n "$R1_KEY" ] && [ -n "$R2_KEY" ] && [ "$C" = "200" ]; then
    preset_bucket "$R1_KEY" 0
    preset_bucket "$R2_KEY" 5
    BEFORE1="$(bucket_tokens "$R1_KEY")"; BEFORE2="$(bucket_tokens "$R2_KEY")"
    BODY="$(curl -s http://localhost:8030/echo)"
    AFTER1="$(bucket_tokens "$R1_KEY")"; AFTER2="$(bucket_tokens "$R2_KEY")"
    report "$([ "$AFTER1" = "0" ] && echo true || echo false)" "R1 empty ⇒ after the request is rejected, R1 tokens unchanged ($BEFORE1→$AFTER1)"
    report "$([ "$AFTER2" = "5" ] && echo true || echo false)" "R2 has 5 ⇒ not consumed ($BEFORE2→$AFTER2)"
    report "$(echo "$BODY" | grep -q '"rule"' && echo true || echo false)" "429 response body contains the rule field ($(echo "$BODY" | grep -o '"rule":"[^"]*' | head -1))"
else
    report false "Scenario 1 precondition failed: first request=$C, group keys R1=$R1_KEY R2=$R2_KEY"
fi

echo "===== Scenario 2/5: all-sufficient pass (each bucket decremented by exactly 1) ====="
NS="rules-allpass"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"; R2_KEY="$(group_bucket "$NS" r2)"
if [ "$C" = "200" ] && [ -n "$R1_KEY" ] && [ -n "$R2_KEY" ]; then
    preset_bucket "$R1_KEY" 5; preset_bucket "$R2_KEY" 5
    C="$(code http://localhost:8030/echo)"
    T1="$(bucket_tokens "$R1_KEY")"; T2="$(bucket_tokens "$R2_KEY")"
    report "$([ "$C" = "200" ] && [ "$T1" = "4" ] && [ "$T2" = "4" ] && echo true || echo false)" \
        "all-sufficient ⇒ passed and each bucket decremented by exactly 1 (HTTP=$C, R1=$T1, R2=$T2)"
else
    report false "Scenario 2 precondition failed: first request=$C"
fi

echo "===== Scenario 3/5: group fingerprint re-buckets (change one rule ⇒ whole group gets new buckets) ====="
NS="rules-fingerprint"
FP_RULES_A='[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]'
FP_RULES_B='[{"limit":10,"window":60},{"limit":6,"window":60,"limit_by":["consumer","path"]}]'
apply_config "$(kong_rules_config_json "$NS" "$FP_RULES_A")" >/dev/null
sleep 2; fresh
code http://localhost:8030/echo >/dev/null
FP_A="$(group_bucket "$NS" r1 | grep -o 'g=[0-9a-f]*' | head -1)"
apply_config "$(kong_rules_config_json "$NS" "$FP_RULES_B")" >/dev/null
sleep 2; fresh
code http://localhost:8030/echo >/dev/null
FP_B="$(group_bucket "$NS" r1 | grep -o 'g=[0-9a-f]*' | head -1)"
report "$([ -n "$FP_A" ] && [ -n "$FP_B" ] && [ "$FP_A" != "$FP_B" ] && echo true || echo false)" \
    "changing only r2.limit ⇒ group fingerprint segment changes ($FP_A → $FP_B)"

echo "===== Scenario 4/5: response semantics (bottleneck header / 429 rule / Retry-After cap) ====="
NS="rules-semantics"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"; R2_KEY="$(group_bucket "$NS" r2)"
# 4a passing-request bottleneck header: R1=5, R2=1.5 (frozen) → after deduction 4/0.5 ⇒ Remaining=0 (bottleneck), Reset≈now+6
preset_bucket "$R1_KEY" 5; preset_bucket "$R2_KEY" 1.5
NOW="$(date +%s)"
HDR="$(curl -s -D- -o /dev/null http://localhost:8030/echo | tr -d '\r')"
C="$(echo "$HDR" | head -1 | awk '{print $2}')"
REM="$(echo "$HDR" | awk -F': ' 'tolower($1)=="x-ratelimit-remaining"{print $2}')"
RESET="$(echo "$HDR" | awk -F': ' 'tolower($1)=="x-ratelimit-reset"{print $2}')"
report "$([ "$C" = "200" ] && [ "$REM" = "0" ] && echo true || echo false)" \
    "passing-request header bottleneck value Remaining=$REM (expected 0, bottleneck R2 has 0.5 left)"
report "$([ "$C" = "200" ] && [ $((RESET - NOW)) -ge 5 ] && [ $((RESET - NOW)) -le 8 ] && echo true || echo false)" \
    "passing-request header Reset−now=$((RESET - NOW)) (expected ≈6 = (1-0.5)/(5/60), bottleneck R2)"
# 4b 429 rule field + Retry-After: R1=0.2 ⇒ wait=4.8 ⇒ Retry-After=5
preset_bucket "$R1_KEY" 0.2; preset_bucket "$R2_KEY" 5
NOW="$(date +%s)"
BODY="$(curl -s -D /tmp/rules-h.txt http://localhost:8030/echo)"
RA="$(tr -d '\r' < /tmp/rules-h.txt | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
report "$([ "$RA" = "5" ] && echo true || echo false)" "429 Retry-After=$RA (expected 5 = ceil(4.8), cap 60)"
report "$(echo "$BODY" | grep -q '"rule":"rules\[1\]' && echo true || echo false)" "429 body rule points to R1 ($(echo "$BODY" | grep -o '"rule":"[^"]*' | head -1))"
# 4c cap: r1 limit=1/window=3600 ⇒ wait=3600 ⇒ Retry-After capped at 3600
NS="rules-cap"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":1,"window":3600},{"limit":100,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"; R2_KEY="$(group_bucket "$NS" r2)"
preset_bucket "$R1_KEY" 0; preset_bucket "$R2_KEY" 5
BODY="$(curl -s -D /tmp/rules-h.txt http://localhost:8030/echo)"
RA="$(tr -d '\r' < /tmp/rules-h.txt | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
report "$([ "$RA" = "3600" ] && echo true || echo false)" "Retry-After cap=$RA (expected 3600 = max window, no larger)"

echo "===== Scenario 5/5: three classes of bad config 400 + valid rules 201 ====="
NS="rules-badcfg"
post() { # post <json> → http code
    curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8031/config \
        -H 'Content-Type: application/json' -d "$1"
}
C1="$(post "$(kong_rules_config_json "$NS-x1" '[{"limit":10,"window":60}]' 0 100 | python3 -c "
import json,sys
cfg=json.load(sys.stdin); cfg['services'][0]['routes'][0]['plugins'][0]['config']['limit_by']=['consumer']
print(json.dumps(cfg))")")"
report "$([ "$C1" = "400" ] && echo true || echo false)" "rules + top-level limit_by together ⇒ 400 (got $C1)"
C2="$(post "$(kong_rules_config_json "$NS-x2" '[{"limit":10,"window":60}]' 20)")"
report "$([ "$C2" = "400" ] && echo true || echo false)" "rules + batch=20 ⇒ 400 (got $C2)"
C3="$(post "$(kong_rules_config_json "$NS-x3" '[{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60}]')")"
report "$([ "$C3" = "400" ] && echo true || echo false)" "9 rules ⇒ 400 (got $C3)"
C4="$(post "$(kong_rules_config_json "$NS-x4" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')")"
report "$([ "$C4" = "201" ] && echo true || echo false)" "valid 2 rules ⇒ 201 (got $C4)"

echo
echo "===== Summary: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
