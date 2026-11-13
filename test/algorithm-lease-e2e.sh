#!/usr/bin/env bash
# ============================================================
# algorithm-lease-e2e.sh —— 6.1 真栈 E2E smoke：三模式路径分流
#
# 覆盖（用户验收测试 §五 1/2/3/4/5/7/11 的 E2E 层，真 Kong + 真 Redis）：
#   batch>1：首请求 GRANT_LEASE（Redis lease 记录 OPEN）+ 当前请求恰好消费 1
#            （X-RateLimit-Remaining = granted-1）；后续请求本地 TAKE 零新 GRANT；
#            本地耗尽 ⇒ 再申请（第二条 lease 记录，旧记录不覆盖——并存）
#   batch=1：完全不产生 lease 记录（TOKEN_BUCKET 记录存在）
#   多规则：GRANT_MULTI 双桶扣减，零 lease 记录
# 运行：bash+curl；前置：三节点已重启加载新代码（docker compose restart）
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

# 每次运行独立 namespace（含时间戳）⇒ 新策略指纹 ⇒ 本地库存与 Redis 记录全隔离
# （Redis FLUSHDB 清不掉 Worker 本地 Lease 库存——V1 冻结语义，故必须换指纹）
NS_G1="rl6g1$$"; NS_B1="rl6b1$$"; NS_M="rl6m$$"

# ---- 1. 下发三路由配置（DB-less 整体替换，三节点同配置） ----
mkdir -p /tmp/opencode
cat <<EOF > /tmp/opencode/rl6-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"echo-route","paths":["/echo"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"${NS_G1}",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]},
  {"name":"echo-b1","paths":["/b1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"${NS_B1}",
     "window":3600,"limit":50,"batch":1,"burst":0,"limit_by":["ip"],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]},
  {"name":"echo-multi","paths":["/multi"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"${NS_M}",
     "limit":50,"window":3600,"burst":0,"fault_tolerant":false,
     "redis":{"host":"redis","port":6379,"database":0,"timeout":1000},
     "rules":[{"limit":100,"window":3600,"limit_by":["ip"]},
              {"limit":50,"window":3600,"limit_by":["ip"]}]}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl6-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "三节点配置下发完成（batch=10 / batch=1 / 多规则）"

# ---- 2. 清空 Redis，保证从零观察 ----
RC FLUSHDB >/dev/null

# lease 记录按 pool_key 字段归属 namespace（lease key 本身不含 namespace）
lease_ns_count() {
  RC --scan --pattern 'kong:rl:lease:*' \
   | while IFS= read -r k; do [ -n "$k" ] && RC HGET "$k" pool_key </dev/null; done \
   | grep -c "$1" || true
}
lease_status() { RC HGET "$1" status; }

# ---- 3. batch>1：单连接 10 连发（1 GRANT + 9 本地 TAKE，同 worker 确定性）----
urls=$(for i in $(seq 1 10); do echo "-o /dev/null $PROXY/echo"; done)
out=$(curl -s -D /tmp/opencode/rl6-h1.txt -w '%{http_code}\n' $urls)
rem1=$(sed -n 's/^x-ratelimit-remaining: //pi' /tmp/opencode/rl6-h1.txt | tr -d '\r')
code=$(head -1 <<<"$out")
# 10 个响应的 remaining 追加在同一文件：9,8,…,0 ⇒ 每请求恰好消费 1，第 10 个耗尽
rem_trace=$(echo "$rem1" | tr '\n' ' ')
expect="9 8 7 6 5 4 3 2 1 0 "
report "$(eq "$code" 200)" "首请求 HTTP 状态=$code（应为 200）"
report "$(eq "$rem_trace" "$expect")" "remaining 序列=[$rem_trace]（应=$expect：每请求恰好消费 1，GRANT 后不漏当前请求、不重复消费）"
n1=$(lease_ns_count "$NS_G1")
report "$(eq "$n1" 1)" "10 请求后 lease 记录数=$n1（应为 1：1 次 GRANT + 9 次本地 TAKE，同 worker 零新 GRANT）"
# 仅取本次 namespace 的 lease 记录（按 pool_key 归属，防残留干扰）
lkey=$(RC --scan --pattern 'kong:rl:lease:*' | while IFS= read -r k; do
    [ -n "$k" ] && RC HGET "$k" pool_key </dev/null | grep -q "$NS_G1" && echo "$k"
  done | head -1)
[ -n "$lkey" ] || { bad "未找到 $NS_G1 的 lease 记录"; exit 1; }
report "$(eq "$(lease_status "$lkey")" OPEN)" "lease 记录 status=$(lease_status "$lkey")（应为 OPEN）"
pk=$(RC HGET "$lkey" pool_key)
bkt=$(RC --scan --pattern "kong:rl:*${NS_G1}*" | grep -v lease | head -1)
report "$(eq "$pk" "$bkt")" "pool_key == 桶键（D7：pool_key=既有桶键）| $pk vs $bkt"

# ---- 5. 再 11 请求（新连接 ⇒ 可能另一 worker）：本地耗尽 ⇒ 再申请 ----
# 21 个请求消费 21 令牌，每 Lease 至多 10 ⇒ 全局至少 3 条 GRANT 记录（无跨 worker 共享）
urls=$(for i in $(seq 11 21); do echo "-o /dev/null $PROXY/echo"; done)
codes=$(curl -s -w '%{http_code}\n' $urls)
report "$(eq "$(printf '%s\n' "$codes" | grep -vc 200)" 0)" "请求 11-21 全部 200"
n2=$(lease_ns_count "$NS_G1")
report "$([ "$n2" -ge 3 ] && echo true)" "21 请求后 lease 记录数=$n2（应≥3：每 Lease ≤10 且无跨 worker 接管）"
report "$(eq "$(lease_status "$lkey")" OPEN)" "首条 lease 记录仍在且 status=$(lease_status "$lkey")（并存不覆盖；V1 无 RETURN ⇒ Redis 侧 OPEN——CLOSED 为本地语义）"

# ---- 6. batch=1：零 lease 记录 ----
for i in 1 2 3; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/b1")
  [ "$c" = "200" ] || bad "batch=1 第 $i 请求状态=$c"
done
report "$(eq "$(lease_ns_count "$NS_B1")" 0)" "batch=1 产生 lease 记录数=$(lease_ns_count "$NS_B1")（应为 0）"
b1_bucket=$(RC --scan --pattern "kong:rl:*${NS_B1}*" | grep -vc lease || true)
report "$(eq "$b1_bucket" 1)" "batch=1 桶记录数=$b1_bucket（TOKEN_BUCKET 正常扣减）"

# ---- 7. 多规则：GRANT_MULTI 双桶、零 lease ----
h=$(curl -s -D - -o /dev/null "$PROXY/multi")
code=$(head -1 <<<"$h" | awk '{print $2}')
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$code" 200)" "多规则请求状态=$code"
report "$(eq "$rem" "49")" "多规则 X-RateLimit-Remaining=$rem（瓶颈规则 limit=50 消费 1 ⇒ 49）"
report "$(eq "$(lease_ns_count "$NS_M")" 0)" "多规则产生 lease 记录数=$(lease_ns_count "$NS_M")（应为 0）"
m_bucket=$(RC --scan --pattern "kong:rl:*${NS_M}*" | grep -vc lease || true)
report "$(eq "$m_bucket" 2)" "多规则桶记录数=$m_bucket（GRANT_MULTI 双桶原子扣减）"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
