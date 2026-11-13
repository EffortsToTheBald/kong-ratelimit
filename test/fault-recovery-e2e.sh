#!/usr/bin/env bash
# ============================================================
# fault-recovery-e2e.sh —— 6.4 故障恢复验证（真栈，§7.3）
#
# 场景：
#   R1 连接拒绝 → 恢复：
#     stop redis ⇒ 503（Fail-close，Fresh ns ⇒ GRANT 失败）；
#     start redis ⇒ 请求正常放行 200；该 ns lease 记录恰 1 条
#     （连接拒绝期间 Redis 停机 ⇒ 侧零写入是确定性事实；恢复后单次授权）
#   R2 CLIENT PAUSE 超时 → 恢复：
#     PAUSE 6s ⇒ 并行请求 ⇒ 503（不确定，不重试不登记）；
#     PAUSE 过期 ⇒ 恢复后请求 200；ns lease 记录数 = 恢复前记录数 + 恰 1
#     （增量断言：允许超时期间 Redis 已执行产生记录——不违反 GRANT 超时冻结语义；
#      仅证明恢复后一次请求 = 恰一次授权，无重复授权）
# 前置：三节点健康；独立 namespace；不修改 6.2 已通过语义
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
NS_R1="p64r1$$"; NS_R2="p64r2$$"

cat <<EOF > /tmp/opencode/rl64r-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"r1","paths":["/r1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_R1",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"r2","paths":["/r2"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_R2",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl64r-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "双路由配置下发（batch>1 ft=false × 2）"

lease_records_for() {
  RC --scan --pattern 'kong:rl:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$1"*) echo "$k";; esac
  done
}

# ================= R1：连接拒绝 → 恢复 =================
docker compose stop redis >/dev/null 2>&1
sleep 1
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/r1")
report "$(eq "$c" 503)" "R1 故障期请求 ⇒ $c（应为 503 Fail-close；未伪装 429）"
docker compose start redis >/dev/null 2>&1
for t in $(seq 1 20); do RC PING >/dev/null 2>&1 && break; sleep 1; done
ok "Redis 已恢复（PING 通）"
h=$(curl -s -D - -o /dev/null "$PROXY/r1")
c=$(head -1 <<<"$h" | awk '{print $2}')
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$c" 200)" "R1 恢复后独立请求 ⇒ $c（应为 200，正常申请）"
report "$(eq "$rem" "9")" "R1 恢复后 remaining=$rem（新 GRANT granted=10 消费 1；未把故障期失败当已授权）"
n1=$(lease_records_for "$NS_R1" | wc -l | tr -d ' ')
report "$(eq "$n1" 1)" "R1 该 ns lease 记录数=$n1（恰 1：连接拒绝期间 Redis 停机零写入；恢复后单次授权，无重复授权）"

# ================= R2：CLIENT PAUSE 超时 → 恢复 =================
RC CLIENT PAUSE 6000 >/dev/null
curl -s -o /dev/null -w 'r2=%{http_code}\n' --max-time 8 "$PROXY/r2" > /tmp/opencode/rl64r-t1 &
curl -s -o /dev/null -w 'r2=%{http_code}\n' --max-time 8 "$PROXY/r2" > /tmp/opencode/rl64r-t2 &
wait
c1=$(sed -n 's/^r2=//p' /tmp/opencode/rl64r-t1); c2=$(sed -n 's/^r2=//p' /tmp/opencode/rl64r-t2)
report "$(eq "$c1$([ "$c2" != "$c1" ] && echo ".$c2" || echo "")" "503")" "R2 超时并行请求 ⇒ [$c1${c2:+,$c2}]（应 503：不确定结果进故障分支，不伪装 429/不重试）"
sleep 5
ok "PAUSE 已过期"
n2_before=$(lease_records_for "$NS_R2" | wc -l | tr -d ' ')
h=$(curl -s -D - -o /dev/null "$PROXY/r2")
c=$(head -1 <<<"$h" | awk '{print $2}')
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$c" 200)" "R2 恢复后独立请求 ⇒ $c（应为 200）"
report "$(eq "$rem" "9")" "R2 恢复后 remaining=$rem（正常新 GRANT）"
n2_after=$(lease_records_for "$NS_R2" | wc -l | tr -d ' ')
delta=$((n2_after - n2_before))
report "$(eq "$delta" 1)" "R2 lease 记录增量=+$delta（恢复前=$n2_before[允许 0 或 1：超时可能已执行]，恢复后恰 +1 ⇒ 无重复授权）"
report "$([ "$n2_before" -le 1 ] && echo true)" "R2 超时窗口记录数=$n2_before ≤1（不确定结果不重复申请：两次并行请求至多产生 1 条记录——单请求恰一次 GRANT）"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
