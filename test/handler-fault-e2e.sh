#!/usr/bin/env bash
# ============================================================
# handler-fault-e2e.sh —— 6.2 故障分支真栈验证（真实故障注入）
#
# 场景矩阵（真 Kong + 真 Redis 故障注入，非 mock）：
#   Redis 正常有额度           ⇒ 200
#   Redis 额度不足（batch>1 / batch=1）⇒ 429 + Retry-After
#   Redis 连接拒绝（docker compose stop redis）⇒ 503（ft=false）/ degraded（ft=true）
#   Redis 超时（CLIENT PAUSE > timeout）⇒ 503（ft=false）/ degraded（ft=true）
#   batch=1 / batch>1 故障同为 503（Fail-close 语义不随路径变化）
#   本地已有库存 + Redis 故障 ⇒ 200（本地 TAKE 零 IO——设计语义，见报告）
# 日志证据：failing closed / failing open / lease grant failed (uncertain)
# 前置：三节点已重启加载新 handler；每次运行独立 namespace
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
# 按 lease_id 第二字段（host:worker:seq:hex）输出指定 ns 下全部 Lease 的 worker_id
# ——Lease 记录总数无法区分"同一 Worker 多次 GRANT"，Worker 归属必须看 worker_id
lease_worker_ids() {
  RC --scan --pattern 'kong:rl:lease:*' </dev/null \
   | while IFS= read -r k; do
       [ -n "$k" ] || continue
       pk=$(RC HGET "$k" pool_key </dev/null)
       case "$pk" in
         *"$1"*) RC HGET "$k" lease_id </dev/null | awk -F: '{print $2}' ;;
       esac
     done
}
PROXY="http://localhost:8030"
RLCONFIG='{"host":"redis","port":6379,"database":0,"timeout":1000}'
RED="\"fault_tolerant\":false,\"redis\":$RLCONFIG"
GRN="\"fault_tolerant\":true,\"redis\":$RLCONFIG"

NS() { echo "$1$$"; }
NS_2D=$(NS h2d); NS_2U=$(NS h2u); NS_1D=$(NS h1d); NS_1U=$(NS h1u)
NS_2R=$(NS h2r); NS_1R=$(NS h1r); NS_2N=$(NS h2n)

# ---- 1. 下发 7 路由配置 ----
cat <<EOF > /tmp/opencode/rl62-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"h-2d","paths":["/h2d"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2D",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RED}}]},
  {"name":"h-2u","paths":["/h2u"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2U",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$GRN}}]},
  {"name":"h-1d","paths":["/h1d"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_1D",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$RED}}]},
  {"name":"h-1u","paths":["/h1u"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_1U",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$GRN}}]},
  {"name":"h-2r","paths":["/h2r"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2R",
     "window":3600,"limit":5,"batch":5,"burst":5,"limit_by":["ip"],$RED}}]},
  {"name":"h-1r","paths":["/h1r"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_1R",
     "window":3600,"limit":3,"batch":1,"burst":0,"limit_by":["ip"],$RED}}]},
  {"name":"h-2n","paths":["/h2n"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2N",
     "window":3600,"limit":100,"batch":50,"burst":0,"limit_by":["ip"],$RED}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl62-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "三节点配置下发完成（7 路由：batch>1/batch=1 × ft=false/true × 正常/429）"

# ---- 2. Redis 正常：放行 / 429 矩阵 ----
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h2n")
report "$(eq "$code" 200)" "Redis 正常 + 有额度 ⇒ $code（应为 200）"

# batch>1 429：单连接 6 连发（固定 worker）⇒ 1 GRANT(5)+4 本地 TAKE+第 6 请求桶空 granted=0 ⇒ 429
# （多 worker 下位置假设不成立：每个新连接可能换 worker，必须同连接确定性构造）
urls=$(for i in $(seq 1 6); do echo "-o /dev/null $PROXY/h2r"; done)
codes=$(curl -s -w '%{http_code}\n' $urls | tr -d '\r')
seq_codes=$(printf '%s\n' "$codes" | awk '{print $1}' | tr '\n' ' ')
report "$(eq "$seq_codes" "200 200 200 200 200 429 ")" "batch>1 429 序列=[$seq_codes]（应=200×5 后 429：本地 TAKE 4 个 + 第 6 请求 granted=0）"
# 6 连发后两 worker 的 GRANT 均空桶（granted=0）⇒ 任一新连接请求必为 429 ⇒ 探针确定
h=$(curl -s -D - -o /dev/null "$PROXY/h2r")
ra=$(sed -n 's/^Retry-After: //pi' <<<"$h" | tr -d '\r')
report "$([ -n "$ra" ] && [ "$ra" -ge 1 ] && echo true)" "429 Retry-After=$ra（既有契约）"
rem6=$(curl -s -D - -o /dev/null "$PROXY/h2r" | sed -n 's/^X-RateLimit-Remaining: //pi' | tr -d '\r')
report "$(eq "$rem6" "0")" "429 X-RateLimit-Remaining=$rem6（应为 0；此时两 worker 的 GRANT 均空桶 ⇒ 新请求必 429）"
body=$(curl -s "$PROXY/h2r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])')
report "$(eq "$body" "API rate limit exceeded")" "429 响应体=$body"

# batch=1 429：limit=3 ⇒ 第 4 请求 429
for i in 1 2 3; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h1r")
  [ "$c" = "200" ] || bad "h1r 第 $i 请求=$c（应 200）"
done
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h1r")
report "$(eq "$code" 429)" "batch=1 额度不足 ⇒ $code（应为 429）"

# ---- 2b. 故障前置：让至少两个不同 Worker 持有本地库存 ----
# 证明口径（审查修正一）：按 lease_id 的 worker_id 字段统计**不同 Worker 数**；
# 每个 Worker 首个请求各自 GRANT（Worker 隔离）。batch=50 ⇒ 任一 Worker 首 GRANT 得
# 50 个令牌，≤40 次前置请求不足以耗尽任一 Worker 库存，
# 故"≥2 个不同 worker_id 成功创建 Lease" ⇔ 两个 Worker 均持有剩余库存。
TWO_WORKERS=false; wids=""
for i in $(seq 1 40); do
  curl -s -o /dev/null --max-time 5 "$PROXY/h2n" || true
  wids=$(lease_worker_ids "$NS_2N" | sort -u | tr '\n' ',' )
  w=$(lease_worker_ids "$NS_2N" | sort -u | wc -l)
  [ "$w" -ge 2 ] && { TWO_WORKERS=true; break; }
done
if [ "$TWO_WORKERS" = "true" ]; then
  ok "PASS: 双 Worker 库存证明：不同 worker_id=[$wids]（≥2 个 Worker 均创建过 Lease ⇒ 均持剩余库存）"
else
  echo "NOT VERIFIED: 40 次请求未观测到 ≥2 个不同 worker_id（观测=[${wids:-无}]）——不以下述故障期 200 数代替证明"
fi

# ---- 3. 故障注入 A：Redis 连接拒绝（stop redis） ----
docker compose stop redis >/dev/null 2>&1
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h2d")
report "$(eq "$code" 503)" "连接拒绝 batch>1 ft=false ⇒ $code（应为 503，Fail-close）"
body=$(curl -s "$PROXY/h2d" | python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])')
report "$(eq "$body" "rate limiter unavailable")" "503 响应体=$body"
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h1d")
report "$(eq "$code" 503)" "连接拒绝 batch=1 ft=false ⇒ $code（应为 503，Fail-close）"
h=$(curl -s -D - -o /dev/null "$PROXY/h2u")
code=$(head -1 <<<"$h" | awk '{print $2}')
dg=$(sed -n 's/^X-RateLimit-Status: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$code" 200)" "连接拒绝 batch>1 ft=true ⇒ $code（Fail-open 应 200）"
report "$(eq "$dg" "degraded")" "Fail-open 标记 X-RateLimit-Status=$dg（应为 degraded）"
h=$(curl -s -D - -o /dev/null "$PROXY/h1u")
code=$(head -1 <<<"$h" | awk '{print $2}')
dg=$(sed -n 's/^X-RateLimit-Status: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$code" 200)" "连接拒绝 batch=1 ft=true ⇒ $code（Fail-open 应 200）"
report "$(eq "$dg" "degraded")" "Fail-open 标记（batch=1）=$dg（应为 degraded）"
# 设计语义观察：h2n 在步骤 2 已 GRANT（某 worker 持有本地余量）+ Redis 故障：
#   命中有库存 worker ⇒ 本地 TAKE 放行（200，零 IO）；命中空库存 worker ⇒ GRANT 失败 Fail-close（503）。
#   前置已证实两个 worker 均持库存 ⇒ 故障期间任意 worker 的请求都走本地 TAKE ⇒ 全 200（确定性）
obs_codes=$(for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 "$PROXY/h2n" &
done; wait)
obs_dist=$(printf '%s\n' "$obs_codes" | sort | uniq -c | sort -rn | tr '\n' ';')
if [ "$TWO_WORKERS" = "true" ]; then
  report "$(eq "$(printf '%s\n' "$obs_codes" | grep -c 200)" 6)" "观察：本地库存 + Redis 故障 ⇒ 6 连发全 200（分布=[$obs_dist]；本地 TAKE 零 IO，不触故障分支——设计语义）"
else
  report "$(! grep -q 429 <<<"$obs_codes" && echo true)" "观察（降级）：Redis 故障期间无 429（分布=[$obs_dist]；200=库存放行/503=空库存 Fail-close）"
  echo "NOT VERIFIED: 本地 TAKE 故障期放行证据（前置双 Worker 库存未证实，观察项降级为核心不变量）"
fi

# ---- 4. 故障注入 B：Redis 超时（CLIENT PAUSE 6s > timeout 1s，4 请求并行发射）----
# PAUSE 是全局时窗：顺序请求会互相耗光窗口 ⇒ 并行发射保证每个请求都在窗内超时
docker compose start redis >/dev/null 2>&1
for t in $(seq 1 20); do RC PING >/dev/null 2>&1 && break; sleep 1; done
RC CLIENT PAUSE 6000 >/dev/null
curl -s -o /dev/null -w 'h2d=%{http_code}\n' --max-time 8 "$PROXY/h2d"  > /tmp/opencode/rl62-t1 &
curl -s -o /dev/null -w 'h1d=%{http_code}\n' --max-time 8 "$PROXY/h1d"  > /tmp/opencode/rl62-t2 &
curl -s -D /tmp/opencode/rl62-t3.h -o /dev/null -w 'h2u=%{http_code}\n' --max-time 8 "$PROXY/h2u" > /tmp/opencode/rl62-t3 &
curl -s -D /tmp/opencode/rl62-t4.h -o /dev/null -w 'h1u=%{http_code}\n' --max-time 8 "$PROXY/h1u" > /tmp/opencode/rl62-t4 &
wait
code=$(sed -n 's/^h2d=//p' /tmp/opencode/rl62-t1)
report "$(eq "$code" 503)" "Redis 超时（CLIENT PAUSE）batch>1 ft=false ⇒ $code（应为 503；结果不确定不重试不登记）"
code=$(sed -n 's/^h1d=//p' /tmp/opencode/rl62-t2)
report "$(eq "$code" 503)" "Redis 超时 batch=1 ft=false ⇒ $code（应为 503）"
code=$(sed -n 's/^h2u=//p' /tmp/opencode/rl62-t3)
dg=$(sed -n 's/^X-RateLimit-Status: //pi' /tmp/opencode/rl62-t3.h | tr -d '\r')
report "$(eq "$code" 200)" "Redis 超时 batch>1 ft=true ⇒ $code（Fail-open）"
report "$(eq "$dg" "degraded")" "超时 Fail-open 标记=$dg"
code=$(sed -n 's/^h1u=//p' /tmp/opencode/rl62-t4)
dg=$(sed -n 's/^X-RateLimit-Status: //pi' /tmp/opencode/rl62-t4.h | tr -d '\r')
report "$(eq "$code" 200)" "Redis 超时 batch=1 ft=true ⇒ $code（Fail-open）"
report "$(eq "$dg" "degraded")" "超时 Fail-open 标记（batch=1）=$dg"
# 语义说明（审查修正二）：GRANT 超时后 Redis 可能已执行（桶扣减+Lease 记录已建），
# Redis 元数据存在与否**不能**用来证明本地是否登记；不确定结果的"不重试/不登记本地
# 库存/不转 429"由 Phase 4 单测与代码路径保证（test/lease-unit.sh uncertain 用例）。
# 本组真栈验证点 = 超时后的 HTTP 503 / Fail-open 语义（见上方断言与 §5 日志证据）。
sleep 4

# ---- 5. 日志证据 ----
logs=""
for r in 1 2 3; do
  logs=$(docker compose logs kong1 --since 10m 2>&1 || true)
  [ "${#logs}" -gt 1000 ] && break
  sleep 2
done
# 注意：pipefail 下 grep -q（匹配即退出）会令上游 echo 收到 SIGPIPE ⇒ 短路失效；
# 统一用 grep -c（读完全部输入）计数判断
report "$([ "$(echo "$logs" | grep -c "limiter unavailable, failing closed")" -ge 1 ] && echo true)" "日志含 failing closed（Fail-close 证据）"
report "$([ "$(echo "$logs" | grep -c "limiter unavailable, failing open")" -ge 1 ] && echo true)" "日志含 failing open（Fail-open 证据）"
report "$([ "$(echo "$logs" | grep -c "lease grant failed (uncertain)")" -ge 1 ] && echo true)" "日志含 lease grant failed (uncertain)（超时分类证据）"
n429=$(echo "$logs" | grep -c "rate-limit-advanced: 429 " || true)
report "$([ "$n429" -ge 2 ] && echo true)" "日志含 429 判定 notice ×$n429（确定性拒绝与故障日志可区分）"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
