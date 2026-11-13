#!/usr/bin/env bash
# ============================================================
# config-isolation-e2e.sh —— 6.3 配置变更真栈 E2E（limit 维度）
#
# 场景（真 Kong 配置变更，非 mock）：
#   1. 配置 A（limit=100/batch=10/ns 固定）发请求 ⇒ Worker GRANT，本地留库存
#   2. 记录 A 的 lease 记录（lease_id/created_at/status/pool_key）与 A 桶 tokens
#   3. Admin API 变更为配置 B（limit=200，同 ns ⇒ 指纹变化）
#   4. 配置 B 发首个请求：
#      - X-RateLimit-Remaining=9（B 新桶满 ⇒ granted=10 消费 1）；
#        若复用 A 的本地库存则应为 8 ⇒ 断言排除复用
#      - Redis 产生新 lease 记录，pool_key 的指纹段 ≠ A（新 Pool）
#   5. A 的 lease 记录原样保留（lease_id/created_at/status OPEN 不变——未覆盖未删除）
#   6. A 的 Redis 桶 tokens 不因配置变更被修改（±1 容差 = refill/exec 间隔）
# 前置：三节点健康；每次运行独立 namespace
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
PROXY="http://localhost:8030"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'
NS="p63e$$"

apply() {  # $1=limit
  cat <<EOF > /tmp/opencode/rl63-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"c63","paths":["/c63"],"strip_path":false,
  "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
    "window":3600,"limit":$1,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
  for n in 8031 8011 8021; do
    curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
         -H 'Content-Type: application/json' -d @/tmp/opencode/rl63-config.json >/dev/null \
      || { bad "节点 :$n 配置下发失败"; exit 1; }
  done
}

lease_records_for() {  # 输出 ns 的 lease key（按 pool_key 归属）
  RC --scan --pattern 'kong:rl:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$1"*) echo "$k";; esac
  done
}

# ---- 1. 配置 A：GRANT + 本地留库存 ----
apply 100
ok "配置 A 下发完成（limit=100 batch=10 ns=$NS）"
h=$(curl -s -D - -o /dev/null "$PROXY/c63")
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$rem" "9")" "配置 A 首请求 remaining=$rem（granted=10 消费 1 ⇒ 9；本地留 9 个库存）"
alk=$(lease_records_for "$NS" | head -1)
[ -n "$alk" ] || { bad "未找到配置 A 的 lease 记录"; exit 1; }
A_ID=$(RC HGET "$alk" lease_id); A_TS=$(RC HGET "$alk" created_at); A_ST=$(RC HGET "$alk" status)
A_PK=$(RC HGET "$alk" pool_key)
report "$(eq "$A_ST" OPEN)" "A lease 记录 status=$A_ST"
A_BKT=$(RC --scan --pattern "kong:rl:*${NS}*" </dev/null | grep -v lease | head -1)
report "$(eq "$A_PK" "$A_BKT")" "A pool_key == A 桶键"
A_TOK_BEFORE=$(RC HGET "$A_BKT" tokens)

# ---- 2. 配置变更：limit 100 → 200（指纹变化 ⇒ 新 Pool） ----
apply 200
ok "配置变更下发完成（limit=200，同 ns ⇒ 新指纹）"

# ---- 3. 配置 B 首请求：不复用 A 库存 ----
h=$(curl -s -D - -o /dev/null "$PROXY/c63")
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$rem" "9")" "配置 B 首请求 remaining=$rem（B 新桶满 granted=10 消费 1；若复用 A 余 9 库存则应为 8 ⇒ 排除复用）"
n_after=$(lease_records_for "$NS" | wc -l | tr -d ' ')
report "$([ "$n_after" -ge 2 ] && echo true)" "B 首请求触发新 GRANT：ns lease 记录数=$n_after（≥2）"

# ---- 4. 新记录 = B 自己的 Pool（指纹段不同），A 记录原样保留 ----
blks=$(lease_records_for "$NS")
B_PK=""
for k in $blks; do
  [ "$k" = "$alk" ] || B_PK=$(RC HGET "$k" pool_key)
done
[ -n "$B_PK" ] || { bad "未找到配置 B 的 lease 记录"; exit 1; }
report "$(eq "$([ "$B_PK" != "$A_PK" ] && echo true)" "true")" "B pool_key ≠ A pool_key（指纹段隔离）| $A_PK vs $B_PK"
B_ID=$(lease_records_for "$NS" | while IFS= read -r k; do
  [ "$k" = "$alk" ] || RC HGET "$k" lease_id </dev/null; done | head -1)
report "$([ -n "$B_ID" ] && [ "$B_ID" != "$A_ID" ] && echo true)" "B lease_id=$B_ID ≠ A lease_id=$A_ID（多 Lease 并存不覆盖）"
report "$(eq "$(RC HGET "$alk" lease_id)" "$A_ID")" "A lease_id 未被修改"
report "$(eq "$(RC HGET "$alk" created_at)" "$A_TS")" "A created_at 未被修改"
report "$(eq "$(RC HGET "$alk" status)" "$A_ST")" "A status 保持 $A_ST（V1 无 RETURN，旧 Pool 库存自然耗尽/TTL 消亡——冻结决策）"

# ---- 5. A 的 Redis 桶不被配置变更修改 ----
A_TOK_AFTER=$(RC HGET "$A_BKT" tokens)
diff=$(python3 -c "print(abs(float('$A_TOK_AFTER')-float('$A_TOK_BEFORE'))<1.0 and 'yes' or 'no')")
report "$(eq "$diff" "yes")" "A 桶 tokens $A_TOK_BEFORE → $A_TOK_AFTER（±1 容差=refill/exec 间隔；配置变更不修改旧桶令牌状态）"
B_BKT=$(RC --scan --pattern "kong:rl:*${NS}*" </dev/null | grep -v lease | grep "$NS.*p=" | head -1)
report "$(eq "$([ "$B_BKT" != "$A_BKT" ] && echo true)" "true")" "B 桶键 ≠ A 桶键（$A_BKT vs $B_BKT）"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
