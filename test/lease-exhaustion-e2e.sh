#!/usr/bin/env bash
# ============================================================
# lease-exhaustion-e2e.sh —— 6.5 测试2：库存耗尽与重新申请（单连接钉住 Worker）
#
# 场景（batch=10，单 keepalive 连接 ⇒ 同一 Worker 顺序消费）：
#   req1   ⇒ GRANT Lease A（granted=10），消费 1 ⇒ remaining=9
#   req2-10 ⇒ 本地 TAKE ⇒ remaining 8..0（req10 后 Lease A 耗尽 ⇒ 本地 CLOSED 摘除）
#   req11  ⇒ 新 GRANT Lease B（新 lease_id，granted=10）消费 1 ⇒ remaining=9
#   req12  ⇒ remaining=8
# 断言：A≠B；A 库存不被重复消费；B 不复用 A 库存（rem=9 而非 ≥10）；
#       CLOSED 后不再参与 TAKE（req11 触发的是新 GRANT 而非旧库存）；
#       多 Lease 并存管理无退化；不同 Worker 本地库存独立（第二个连接首请求
#       remaining=9 ⇒ 独立 Pool，非共享 8）
# 观测口径：X-RateLimit-Remaining = 本地池余量（algorithm.lua:423-424）
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
NS="p65e$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

RC PING >/dev/null || { bad "Redis 不可用"; exit 1; }
cat <<EOF > /tmp/opencode/p65e-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"exh","paths":["/exh"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
   "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65e-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "配置下发：limit=100 window=86400 batch=10 ns=$NS"

# ---- keepalive HTTP 助手（/dev/tcp；读全响应含 body，保持连接复用） ----
http_req() { # $1=fd $2=path ⇒ 输出 "status remaining"
  printf 'GET /%s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n' "$2" >&"$1" || { echo "ERR send"; return; }
  local line status="" rem="" cl=0
  read -r -t 8 line <&"$1" || { echo "ERR read"; return; }
  status=$(printf '%s' "$line" | awk '{print $2}')
  while IFS= read -r -t 8 line <&"$1"; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
    case "$line" in
      Content-Length:*) cl=${line#*: } ;;
      X-RateLimit-Remaining:*) rem=${line#*: } ;;
    esac
  done
  if [ "${cl:-0}" -gt 0 ] 2>/dev/null; then
    IFS= read -r -N "$cl" -t 8 body <&"$1" || true
  fi
  echo "$status ${rem:-NA}"
}

exec 3<>/dev/tcp/127.0.0.1/8030 || { bad "无法建立 keepalive 连接"; exit 1; }
ok "keepalive 连接建立（fd3，钉住单一 Worker）"

# ---- 12 个顺序请求 ----
declare -a STATUS REM
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  out=$(http_req 3 exh)
  STATUS[$i]=${out%% *}
  REM[$i]=${out#* }
  echo "req$i: status=${STATUS[$i]} remaining=${REM[$i]}"
done
exec 3>&- 3<&-

# ---- 断言：状态码与 remaining 序列 ----
seqok=true
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ "${STATUS[$i]}" = "200" ] || seqok=false
done
report "$seqok" "12 个请求全部 200（耗尽切换不产生错误响应）"
expected="9 8 7 6 5 4 3 2 1 0 9 8"
actual="${REM[1]} ${REM[2]} ${REM[3]} ${REM[4]} ${REM[5]} ${REM[6]} ${REM[7]} ${REM[8]} ${REM[9]} ${REM[10]} ${REM[11]} ${REM[12]}"
report "$(eq "$actual" "$expected")" "remaining 序列=$actual（期望 $expected：A 池 10→0 耗尽，req11 新 GRANT B 池 9）"

# ---- Lease 记录核验（按 created_at 升序：A=先创建，B=耗尽后新 GRANT） ----
recs=$(RC --scan --pattern 'kong:rl:lease:*' </dev/null | while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) echo "$k";; esac
done)
nrec=$(echo "$recs" | grep -c . || true)
report "$(eq "$nrec" 2)" "lease 记录数=$nrec（恰 2：Lease A + Lease B；req11 触发的是新 GRANT，无旧库存静默放行）"
KA=$(echo "$recs" | head -1); KB=$(echo "$recs" | tail -1)
cKA=$(RC HGET "$KA" created_at </dev/null | tr -d '\r'); cKB=$(RC HGET "$KB" created_at </dev/null | tr -d '\r')
if awk -v a="$cKA" -v b="$cKB" 'BEGIN{exit !(b<a)}'; then KA=$(echo "$recs" | tail -1); KB=$(echo "$recs" | head -1); fi
lidA=$(RC HGET "$KA" lease_id </dev/null | tr -d '\r')
lidB=$(RC HGET "$KB" lease_id </dev/null | tr -d '\r')
gA=$(RC HGET "$KA" granted </dev/null | tr -d '\r')
gB=$(RC HGET "$KB" granted </dev/null | tr -d '\r')
cA=$(RC HGET "$KA" created_at </dev/null | tr -d '\r')
cB=$(RC HGET "$KB" created_at </dev/null | tr -d '\r')
sA=$(RC HGET "$KA" status </dev/null | tr -d '\r')
sB=$(RC HGET "$KB" status </dev/null | tr -d '\r')
report "$([ "$lidA" != "$lidB" ] && echo true || echo false)" "Lease A ≠ Lease B（seq: $(echo "$lidA" | cut -d: -f3) vs $(echo "$lidB" | cut -d: -f3)）"
report "$(eq "$gA$gB" "1010")" "两条记录 granted 均=10（A:$gA B:$gB）"
report "$(awk -v a="$cA" -v b="$cB" 'BEGIN{print (b>=a)?"true":"false"}')" "Lease B 创建时间 ≥ A（B 为耗尽后新 GRANT）"
report "$(eq "$sA$sB" "OPENOPEN")" "两记录 status=OPEN（V1：CLOSED 为本地语义，Redis 侧保持 OPEN 至 TTL——冻结口径）"

# ---- 不同 Worker 本地库存独立性 ----
# fd3 所在 Worker 的池（B 池）当前 outstanding=8。新连接命中不同 Worker ⇒
# 独立 Pool ⇒ 新 GRANT ⇒ 记录数 +1（且首请求 remaining=9）；
# 命中同一 Worker ⇒ 共享 B 池 ⇒ remaining 递减（7,6,...）且记录数不变。
# 每次探测为新连接（随机 Worker），最多 8 次；以记录数增加为独立性判据。
indep=false
for t in 1 2 3 4 5 6 7 8; do
  exec 4<>/dev/tcp/127.0.0.1/8030
  out=$(http_req 4 exh)
  exec 4>&- 4<&-
  st=${out%% *}; rm2=${out#* }
  nrec_now=$(RC --scan --pattern 'kong:rl:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$NS"*) echo x;; esac
  done | wc -l | tr -d ' ')
  echo "独立性探测 #$t: status=$st remaining=$rm2 记录数=$nrec_now"
  [ "$st" = "200" ] || continue
  if [ "$nrec_now" -gt "$nrec" ]; then
    indep=true; break
  fi
done
report "$indep" "存在新连接触发独立新 Pool（记录数增加 ⇒ 不同 Worker 本地库存独立，非共享 B 池）"
nrec3=$nrec_now
report "$([ "$nrec3" -ge 3 ] && echo true)" "多 Lease 并存：记录数=$nrec3 ≥3（A/B + 独立 Worker 的新 Lease，并存管理无退化）"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
