#!/usr/bin/env bash
# ============================================================
# worker-crash-e2e.sh —— 6.5 测试3：Worker kill -9 与库存损失（本阶段重点）
#
# 场景（batch=10，limit=100，window=86400 ⇒ 全程 refill<0.1 token）：
#   1. keepalive 连接钉住 kong1 某 Worker W（/proc/net/tcp inode → PID 实证）
#   2. W 上 4 个请求 ⇒ GRANT L1（granted=10），消费 4 ⇒ outstanding=6
#      （X-RateLimit-Remaining 序列 9,8,7,6 实证）
#   3. kill -9 W（PID 实证退出）
#   4. 继续向其余 Worker 发 150 请求 ⇒ 各自新 GRANT
# 账目验收：
#   W 崩溃前：granted(10) = consumed(4) + outstanding(6)
#   W 崩溃后：granted(10) = consumed(4) + lost(6)
#   不接管：全局 allowed = 4 + 90 = 94 ≠ 100（6 个 lost 令牌永不复活）
#   无 RETURN/补偿：L1 记录字段原样（OPEN/granted=10/created_at 不变）
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
NS="p65k$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

RC PING >/dev/null || { bad "Redis 不可用"; exit 1; }
cat <<EOF > /tmp/opencode/p65k-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"crash","paths":["/crash"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
   "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65k-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "配置下发：limit=100 window=86400 batch=10 ns=$NS"

http_req() { # $1=fd $2=path ⇒ "status remaining"
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

# ---- 1. 钉住连接 + PID 映射（请求前，空闲连接已被某 Worker accept） ----
exec 3<>/dev/tcp/127.0.0.1/8030 || { bad "无法建立 keepalive 连接"; exit 1; }
sleep 0.5
inode=$(docker exec kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | head -1 | awk '{print $10}')
report "$([ -n "$inode" ] && echo true)" "连接已建立，inode=$inode（/proc/net/tcp 实证）"
wpid=""
for pid in $(docker exec kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
  if docker exec kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inode\]'" </dev/null; then
    if [ -z "$wpid" ]; then wpid=$pid; else dup=true; fi
  fi
done
report "$([ -n "$wpid" ] && [ -z "${dup:-}" ] && echo true)" "连接归属 Worker PID=$wpid 唯一（inode→fd 实证；kill 目标确定）"

# ---- 2. W 上消费 4 个（granted=10 ⇒ consumed=4, outstanding=6） ----
declare -a REM
for i in 1 2 3 4; do
  out=$(http_req 3 crash)
  st=${out%% *}; REM[$i]=${out#* }
  report "$(eq "$st" 200)" "W 崩溃前 req$i ⇒ $st remaining=${REM[$i]}"
done
exec 3>&- 3<&-
report "$(eq "${REM[1]} ${REM[2]} ${REM[3]} ${REM[4]}" "9 8 7 6")" "outstanding 演进 9→8→7→6（granted=10, consumed=4, outstanding=6）"
L1=$(RC --scan --pattern 'kong:rl:lease:*' </dev/null | while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) echo "$k"; break;; esac
done | head -1)
g1=$(RC HGET "$L1" granted </dev/null | tr -d '\r')
s1=$(RC HGET "$L1" status </dev/null | tr -d '\r')
c1=$(RC HGET "$L1" created_at </dev/null | tr -d '\r')
lid1=$(RC HGET "$L1" lease_id </dev/null | tr -d '\r')
report "$(eq "$g1$s1" "10OPEN")" "W 的 Lease L1：granted=$g1 status=$s1（lease_id=$lid1，worker 段=$(echo "$lid1" | cut -d: -f2)）"

# ---- 3. kill -9 目标 Worker ----
docker exec kong1 kill -9 "$wpid"
alive=true
for t in $(seq 1 20); do
  docker exec kong1 sh -c "ps -o pid= -p $wpid" </dev/null >/dev/null 2>&1 || { alive=false; break; }
  sleep 0.5
done
report "$(eq "$alive" false)" "Worker PID=$wpid 已退出（kill -9 目标确证；期间 10s 轮询 ps）"

# ---- 4. 其余 Worker 继续请求（150 个，新连接） ----
: > /tmp/opencode/p65k-post.txt
for i in $(seq 1 150); do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 "$PROXY/crash" >> /tmp/opencode/p65k-post.txt
done
p200=$(grep -c '^200$' /tmp/opencode/p65k-post.txt || true)
p429=$(grep -c '^429$' /tmp/opencode/p65k-post.txt || true)
pother=$(grep -cv '^200$\|^429$' /tmp/opencode/p65k-post.txt || true)
report "$(eq "$pother" 0)" "崩溃后无 5xx/异常状态码（other=$pother）"
report "$(eq "$p200" 90)" "崩溃后放行=$p200（恰 90：9×batch=10 全部消费；不会重新授权 W 的 6 个 lost）"
report "$(eq "$p429" 60)" "崩溃后 429=$p429（桶耗尽后 denied-GRANT 既有语义）"

# ---- 账目核验 ----
records=0; sum_granted=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) records=$((records+1)); g=$(RC HGET "$k" granted </dev/null | tr -d '\r'); sum_granted=$((sum_granted+g));; esac
done < <(RC --scan --pattern 'kong:rl:lease:*' </dev/null)
report "$(eq "$sum_granted" 100)" "全局 Σgranted=$sum_granted == limit（10 + 9×10；不超发）"
g1b=$(RC HGET "$L1" granted </dev/null | tr -d '\r')
s1b=$(RC HGET "$L1" status </dev/null | tr -d '\r')
c1b=$(RC HGET "$L1" created_at </dev/null | tr -d '\r')
report "$(eq "$g1b$s1b$c1b" "$g1$s1$c1")" "L1 记录原样（granted/status/created_at 不变 ⇒ 无 RETURN、无补偿、无接管）"
bkey=$(RC --scan --pattern 'kong:rl:{'"$NS"':p=*' </dev/null | head -1)
tok=$(RC HGET "$bkey" tokens </dev/null | tr -d '\r')
report "$(awk -v t="$tok" 'BEGIN{print (t<1)?"true":"false"}')" "桶 tokens 终态=$tok < 1（100 个授权令牌全部消化：90 放行 + 6 lost + 4 pre-crash）"

echo ""
echo "================ 库存账目（真实数据） ================"
echo "崩溃 Worker W (PID=$wpid, lease=$lid1):"
echo "  granted=10 (Redis 记录) = consumed 4 (崩溃前 4×200) + outstanding 6 (remaining 序列 9,8,7,6 ⇒ 崩溃前)"
echo "  崩溃后：granted=10 = consumed 4 + lost 6（outstanding 6 归类为 lost，不返还不补偿）"
echo "其余 Worker：granted=$((sum_granted-10)) = consumed $p200 + outstanding 0"
echo "全局：Σgranted=$sum_granted = HTTP 放行 $((4+p200)) + lost 6（无接管：94 ≠ 100）"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
