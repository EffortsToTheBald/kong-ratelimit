#!/usr/bin/env bash
# Phase 3：多规则联合判定验证（D6，独立于 dims.sh，关注点分离）
#
# 用法：./bench/rules.sh
#
# 场景：
#   ① 全或无核心：预置一空一有 → 429 且双桶 tokens 均不变（spec 核心场景）
#   ② 全够放行：各桶恰好各减 1
#   ③ 组指纹换桶：仅改一条规则的 limit → 整组指纹段变化、旧桶不再被命中
#   ④ 响应语义：放行头瓶颈口径 / 429 体 rule 字段 / Retry-After 封顶
#   ⑤ 坏配置三类 400 + 合法 rules 201
#
# 说明：每场景独立 namespace；预置桶用 ts=now+30 冻结 refill（窗口内零补充，
#   断言值精确）；结束后最后一轮配置保留在运行时（后续脚本会整体覆盖）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PASS=0
FAIL=0
report() { # report <true|false> <说明>
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
code() { # code <url> [curl 参数...]
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' "$@" "$url"
}
dexec() { # redis 容器内命令统一入口
    docker compose exec -T redis "$@"
}
# 生成 rules 模式声明式配置（common.sh 的 kong_config_json 不支持 rules，本脚本专用）
# 用法：kong_rules_config_json <ns> <rules_json> [batch] [top_limit]
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
# 取组内桶键：group_bucket <ns> <r1|r2>
group_bucket() {
    dexec sh -c "redis-cli --scan --pattern 'kong:rl:{${1}:*' | grep ':${2}:' | head -1"
}
# 预置桶（ts=now+30 冻结 refill）：preset_bucket <key> <tokens>
preset_bucket() {
    local ts
    ts=$(( $(date +%s) + 30 ))
    dexec redis-cli hset "$1" tokens "$2" ts "$ts" >/dev/null
}
bucket_tokens() { # bucket_tokens <key>
    dexec redis-cli hget "$1" tokens
}

echo "===== 场景 1/5: 全或无核心（一空一有 ⇒ 429 且双桶不变）====="
NS="rules-allornone"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
# 先发一发让双桶落地（新桶=满），拿到真实组键
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"
R2_KEY="$(group_bucket "$NS" r2)"
if [ -n "$R1_KEY" ] && [ -n "$R2_KEY" ] && [ "$C" = "200" ]; then
    preset_bucket "$R1_KEY" 0
    preset_bucket "$R2_KEY" 5
    BEFORE1="$(bucket_tokens "$R1_KEY")"; BEFORE2="$(bucket_tokens "$R2_KEY")"
    BODY="$(curl -s http://localhost:8030/echo)"
    AFTER1="$(bucket_tokens "$R1_KEY")"; AFTER2="$(bucket_tokens "$R2_KEY")"
    report "$([ "$AFTER1" = "0" ] && echo true || echo false)" "R1 空 ⇒ 请求被拒后 R1 tokens 不变（$BEFORE1→$AFTER1）"
    report "$([ "$AFTER2" = "5" ] && echo true || echo false)" "R2 有 5 ⇒ 不被消耗（$BEFORE2→$AFTER2）"
    report "$(echo "$BODY" | grep -q '"rule"' && echo true || echo false)" "429 响应体含 rule 字段（$(echo "$BODY" | grep -o '"rule":"[^"]*' | head -1)）"
else
    report false "场景 1 前置失败：首请求=$C，组键 R1=$R1_KEY R2=$R2_KEY"
fi

echo "===== 场景 2/5: 全够放行（各桶恰好各减 1）====="
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
        "全够 ⇒ 放行且各桶恰好减 1（HTTP=$C, R1=$T1, R2=$T2）"
else
    report false "场景 2 前置失败：首请求=$C"
fi

echo "===== 场景 3/5: 组指纹换桶（改一条规则 ⇒ 整组新桶）====="
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
    "仅改 r2.limit ⇒ 组指纹段变化（$FP_A → $FP_B）"

echo "===== 场景 4/5: 响应语义（瓶颈头 / 429 rule / Retry-After 封顶）====="
NS="rules-semantics"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"; R2_KEY="$(group_bucket "$NS" r2)"
# 4a 放行瓶颈头：R1=5、R2=1.5（冻结）→ 扣后 4/0.5 ⇒ Remaining=0（瓶颈）、Reset≈now+6
preset_bucket "$R1_KEY" 5; preset_bucket "$R2_KEY" 1.5
NOW="$(date +%s)"
HDR="$(curl -s -D- -o /dev/null http://localhost:8030/echo | tr -d '\r')"
C="$(echo "$HDR" | head -1 | awk '{print $2}')"
REM="$(echo "$HDR" | awk -F': ' 'tolower($1)=="x-ratelimit-remaining"{print $2}')"
RESET="$(echo "$HDR" | awk -F': ' 'tolower($1)=="x-ratelimit-reset"{print $2}')"
report "$([ "$C" = "200" ] && [ "$REM" = "0" ] && echo true || echo false)" \
    "放行头瓶颈口径 Remaining=$REM（期望 0，瓶颈 R2 剩 0.5）"
report "$([ "$C" = "200" ] && [ $((RESET - NOW)) -ge 5 ] && [ $((RESET - NOW)) -le 8 ] && echo true || echo false)" \
    "放行头 Reset−now=$((RESET - NOW))（期望 ≈6 = (1-0.5)/(5/60)，瓶颈 R2）"
# 4b 429 rule 字段 + Retry-After：R1=0.2 ⇒ wait=4.8 ⇒ Retry-After=5
preset_bucket "$R1_KEY" 0.2; preset_bucket "$R2_KEY" 5
NOW="$(date +%s)"
BODY="$(curl -s -D /tmp/rules-h.txt http://localhost:8030/echo)"
RA="$(tr -d '\r' < /tmp/rules-h.txt | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
report "$([ "$RA" = "5" ] && echo true || echo false)" "429 Retry-After=$RA（期望 5 = ceil(4.8)，封顶 60）"
report "$(echo "$BODY" | grep -q '"rule":"rules\[1\]' && echo true || echo false)" "429 体 rule 指向 R1（$(echo "$BODY" | grep -o '"rule":"[^"]*' | head -1)）"
# 4c 封顶：r1 limit=1/window=3600 ⇒ wait=3600 ⇒ Retry-After 不超过 3600
NS="rules-cap"
apply_config "$(kong_rules_config_json "$NS" '[{"limit":1,"window":3600},{"limit":100,"window":60,"limit_by":["consumer","path"]}]')" >/dev/null
sleep 2; fresh
C="$(code http://localhost:8030/echo)"
R1_KEY="$(group_bucket "$NS" r1)"; R2_KEY="$(group_bucket "$NS" r2)"
preset_bucket "$R1_KEY" 0; preset_bucket "$R2_KEY" 5
BODY="$(curl -s -D /tmp/rules-h.txt http://localhost:8030/echo)"
RA="$(tr -d '\r' < /tmp/rules-h.txt | awk -F': ' 'tolower($1)=="retry-after"{print $2}')"
report "$([ "$RA" = "3600" ] && echo true || echo false)" "Retry-After 封顶=$RA（期望 3600 = max window，不更大）"

echo "===== 场景 5/5: 坏配置三类 400 + 合法 rules 201 ====="
NS="rules-badcfg"
post() { # post <json> → http code
    curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:8031/config \
        -H 'Content-Type: application/json' -d "$1"
}
C1="$(post "$(kong_rules_config_json "$NS-x1" '[{"limit":10,"window":60}]' 0 100 | python3 -c "
import json,sys
cfg=json.load(sys.stdin); cfg['services'][0]['routes'][0]['plugins'][0]['config']['limit_by']=['consumer']
print(json.dumps(cfg))")")"
report "$([ "$C1" = "400" ] && echo true || echo false)" "rules+顶层 limit_by 同现 ⇒ 400（实际 $C1）"
C2="$(post "$(kong_rules_config_json "$NS-x2" '[{"limit":10,"window":60}]' 20)")"
report "$([ "$C2" = "400" ] && echo true || echo false)" "rules+batch=20 ⇒ 400（实际 $C2）"
C3="$(post "$(kong_rules_config_json "$NS-x3" '[{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60},{"limit":10,"window":60}]')")"
report "$([ "$C3" = "400" ] && echo true || echo false)" "9 条规则 ⇒ 400（实际 $C3）"
C4="$(post "$(kong_rules_config_json "$NS-x4" '[{"limit":10,"window":60},{"limit":5,"window":60,"limit_by":["consumer","path"]}]')")"
report "$([ "$C4" = "201" ] && echo true || echo false)" "合法 2 规则 ⇒ 201（实际 $C4）"

echo
echo "===== 汇总: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
