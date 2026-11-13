#!/usr/bin/env bash
# ============================================================
# lease-timeout-uncertain-e2e.sh —— 6.5 测试4：Redis 超时与不确定结果
#
# 三种情况严格区分（不得混淆）：
#   P1 已确认库存期间 Redis 暂停：本地 TAKE 正常（确认库存仍可消费）；
#      库存耗尽 ⇒ 新 GRANT 进既有故障分支（503，非 429）
#   A Redis 未执行 GRANT（PAUSE WRITE 拦截 + CLIENT KILL 丢弃，确定性未执行）：
#      503 ⇒ 记录数==0 ⇒ 后续请求正常新 GRANT
#   B Redis 已执行但响应丢失（SIGSTOP 冻结 + Kong 超时关连接 + SIGCONT 后
#      Redis 消费内核缓冲命令 ⇒ 真实执行、响应丢失）：
#      503 ⇒ 不重试（记录 ≤1）⇒ 不登记本地库存（同 Worker 后续请求 rem=9
#      且记录 +1）⇒ 后续独立请求按正常流程重新申请
#   granted=0（明确拒绝 ⇒ 429）由 quota.sh b20 / concurrent-lease-e2e 覆盖
# 冻结口径：不确定结果不重试、不登记本地库存、不当作 granted=0；
#          不得要求超时后 Redis 记录必须为 0（B 场景记录恰 1）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0; NOTV=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
notv() { printf '\033[33m%s\033[0m\n' "$*" >&2; NOTV=$((NOTV+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
RCW() { timeout 15 docker compose exec -T redis redis-cli "$@"; }
PROXY="http://localhost:8030"
NS1="p65t1$$"; NS2="p65t2$$"; NS3="p65t3$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

RC PING >/dev/null || { bad "Redis 不可用"; exit 1; }
cat <<EOF > /tmp/opencode/p65t-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"tmo1","paths":["/tmo1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS1",
     "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"tmo2","paths":["/tmo2"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS2",
     "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"tmo3","paths":["/tmo3"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS3",
     "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65t-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "配置下发：三路由 batch=10 ft=false timeout=1000 window=86400"

http_req() { # $1=fd $2=path ⇒ "status remaining"
  printf 'GET /%s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n' "$2" >&"$1" || { echo "ERR send"; return; }
  local line status="" rem="" cl=0
  read -r -t 10 line <&"$1" || { echo "ERR read"; return; }
  status=$(printf '%s' "$line" | awk '{print $2}')
  while IFS= read -r -t 10 line <&"$1"; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
    case "$line" in
      Content-Length:*) cl=${line#*: } ;;
      X-RateLimit-Remaining:*) rem=${line#*: } ;;
    esac
  done
  if [ "${cl:-0}" -gt 0 ] 2>/dev/null; then
    IFS= read -r -N "$cl" -t 10 body <&"$1" || true
  fi
  echo "$status ${rem:-NA}"
}
lease_count() { # $1=ns ⇒ 记录数
  RC --scan --pattern 'kong:rl:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$1"*) echo x;; esac
  done | wc -l | tr -d ' '
}
wait_unpause() { # PAUSE 期间 PING 也被阻塞 ⇒ 阻塞至解除后返回
  RCW PING >/dev/null
}

# ================= P1：确认库存期间 PAUSE + 耗尽后 GRANT 故障分支 =================
exec 3<>/dev/tcp/127.0.0.1/8030
out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "P1 req1 ⇒ 200 remaining=$rm（GRANT L1，建立确认库存）"
RC CLIENT PAUSE 4000 >/dev/null
ok "CLIENT PAUSE 4000（P1 窗口开始）"
p1ok=true; seqexp="8 7 6 5 4 3 2 1 0"; seqgot=""
for i in 2 3 4 5 6 7 8 9 10; do
  out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
  seqgot="$seqgot $rm"
  [ "$st" = "200" ] || p1ok=false
done
report "$p1ok" "P1 req2-10 ⇒ 全部 200（Redis 暂停期间确认库存仍可本地 TAKE）"
report "$(eq "${seqgot# }" "$seqexp")" "P1 remaining 序列=${seqgot# }（本地 TAKE 逐个消费至 0；与 Redis 无关）"
out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
report "$(eq "$st" "503")" "P1 库存耗尽后 req11 ⇒ $st（新 GRANT 超时 ⇒ 既有故障分支；非 429、非重试）"
wait_unpause
ok "P1 窗口结束（PING 通）"
out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "P1 恢复后请求 ⇒ 200 remaining=$rm（正常新 GRANT L2）"
exec 3>&- 3<&-

# ================= A：Redis 未执行 GRANT（PAUSE WRITE + CLIENT KILL） =================
# PAUSE WRITE：EVALSHA（写命令）被拦截排队，CLIENT LIST/KILL（管理命令）仍可用；
# 0.5s 时杀掉 Kong 的 Redis 连接（先于 Kong 1s 超时）⇒ EOF ⇒ 确定性失败分支；
# 排队命令随连接缓冲丢弃 ⇒ Redis 确定性未执行 ⇒ 记录数==0。
exec 4<>/dev/tcp/127.0.0.1/8030
RC CLIENT PAUSE 5000 WRITE >/dev/null
ok "A：CLIENT PAUSE 5000 WRITE（EVALSHA 拦截排队，管理命令可用）"
curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/tmo3" > /tmp/opencode/p65t-a.txt &
curlpid=$!
sleep 0.5
killed=0
for a in $(RC CLIENT LIST </dev/null | grep -o 'addr=172\.18\.[0-9.]*:[0-9]*' | cut -d= -f2 | sort -u); do
  RC CLIENT KILL ADDR "$a" </dev/null | grep -q '1$\|OK' && killed=$((killed+1))
done
wait $curlpid
stA=$(cat /tmp/opencode/p65t-a.txt)
report "$(eq "$stA" "503")" "A 请求 ⇒ $stA（连接被杀 ⇒ 确定性失败分支；非 429）"
report "$([ "$killed" -ge 1 ] && echo true)" "A 已执行 CLIENT KILL×$killed（先于 Kong 超时；排队 EVALSHA 随连接丢弃 ⇒ Redis 确定性未执行）"
RC CLIENT UNPAUSE >/dev/null 2>&1 || true
ok "A：UNPAUSE（WRITE 模式下读命令本就可用）"
nA=$(lease_count "$NS3")
report "$(eq "$nA" 0)" "A 该 ns lease 记录数=$nA（恰 0：命令从未执行——与 B 场景区分的关键）"
out=$(http_req 4 tmo3); st=${out%% *}; rm=${out#* }
report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "A 恢复后请求 ⇒ $st remaining=$rm（正常新 GRANT，无幻影库存）"
exec 4>&- 4<&-

# ================= B：Redis 已执行但响应丢失（SIGSTOP/SIGCONT） =================
# PAUSE 无法制造"已执行但响应丢失"：Kong 超时(1s)后关闭 cosocket，排队命令被
# 丢弃（实测记录=0）。改用 SIGSTOP/SIGCONT：请求发出后冻结 Redis（命令停留在
# 内核缓冲区未被处理）；Kong 1s 超时 ⇒ 503 并关闭 redis cosocket；CONT 后
# Redis 消费缓冲命令 ⇒ 真实执行（记录=1），响应写到已关闭的 cosocket ⇒ 丢失。
# Worker 归属证据：超时请求与后续请求共用同一条 fd5 keepalive 客户端连接；
# 连接 → /proc/net/tcp inode → worker fd → PID 唯一映射，前后两次核对一致
# ⇒ 两请求确由同一 Worker 处理（非仅同一 Kong 节点）。
# 验收：503（不确定进故障分支）⇒ 记录恰 1（不重试）⇒ 同一 Worker 的后续请求
# remaining=9 且记录 +1（不确定结果未登记本地库存，按正常流程重新申请）。
# 若 Kong 在 503 后关闭了客户端连接（fd5 inode 消失），则同 Worker 无法证明
# ⇒ 标记 NOT VERIFIED，不降低验收标准。
exec 5<>/dev/tcp/127.0.0.1/8030 || { bad "B：无法建立 fd5 keepalive 连接"; exit 1; }
sleep 0.5
inodeB=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | awk '{print $10}' | sort | uniq -c | awk '$1==1{print $2}' | head -1)
nconn=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -icE ':1F40 ' || true)
report "$(eq "$nconn" 1)" "B fd5 连接唯一（ESTAB 客户端连接数=$nconn，inode=$inodeB）"
wpidB=""
for pid in $(docker compose exec -T kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
  if docker compose exec -T kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inodeB\]'" </dev/null; then
    wpidB="$wpidB $pid"
  fi
done
report "$(eq "$(echo $wpidB | wc -w | tr -d ' ')" 1)" "B fd5 归属 Worker PID 唯一=[$wpidB]（inode→fd→PID 实证）"
# 先 STOP 再发请求（确定性）。注意：PID namespace 内部向 PID 1 发送默认处置
# 信号（SIGSTOP）会被内核丢弃——必须从宿主机对容器 init 进程的宿主 PID 发信号
# （namespace 外部信号才生效）。宿主机非 root ⇒ 经 --pid host + privileged 的
# busybox 发送 namespace 外部信号。
RPID=$(docker inspect kong-ratelimit-redis-1 --format '{{.State.Pid}}')
docker run --rm --pid host --privileged busybox kill -STOP "$RPID" && echo "B：SIGSTOP redis（宿主 PID=$RPID，状态 T）"
out=$(http_req 5 tmo2); stB=${out%% *}; rmB=${out#* }
report "$(eq "$stB" "503")" "B 超时请求（经 fd5，Worker=[$wpidB]）⇒ $stB（不确定结果进故障分支；非 429、不盲目重试——单请求单失败）"
# 503 后验证 fd5 客户端连接仍存活且归属未变（不假设可复用）；若 Kong 关闭了
# 客户端连接 ⇒ 同 Worker 无法证明 ⇒ 后续断言标记 NOT VERIFIED（不降低标准）
inodeB2=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | awk '{print $10}' | sort | uniq -c | awk '$1==1{print $2}' | head -1)
survived=false; wpidB2=""
if [ -n "$inodeB2" ] && [ "$inodeB2" = "$inodeB" ]; then
  for pid in $(docker compose exec -T kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
    if docker compose exec -T kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inodeB2\]'" </dev/null; then
      wpidB2="$wpidB2 $pid"
    fi
  done
  [ "$wpidB2" = "$wpidB" ] && survived=true
fi
report "$survived" "B fd5 在 503 后仍存活且归属不变（inode 同、Worker PID=[$wpidB2]）"
docker run --rm --pid host --privileged busybox kill -CONT "$RPID" && echo "B：SIGCONT（Redis 消费缓冲命令 ⇒ 真实执行、响应丢失）"
sleep 0.5
nB1=$(lease_count "$NS2")
report "$(eq "$nB1" 1)" "B 该 ns lease 记录数=$nB1（恰 1：真实执行且仅执行一次；若重试则 ≥2 ⇒ FAIL）"
if [ "$survived" = "true" ]; then
  out=$(http_req 5 tmo2); st=${out%% *}; rm=${out#* }
  report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "B 后续请求（同一 fd5，同一 Worker PID=[$wpidB2]）⇒ $st remaining=$rm（不确定结果未登记本地库存——若登记则同 Worker rem=8 且无新记录）"
  nB2=$(lease_count "$NS2")
  report "$(eq "$nB2" $((nB1+1)))" "B 记录增量=+$((nB2-nB1))（同 Worker 后续独立请求按正常流程重新申请新 Lease，未复用不确定结果）"
  inodeB3=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
    | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | awk '{print $10}' | sort | uniq -c | awk '$1==1{print $2}' | head -1)
  wpidB3=""
  if [ -n "$inodeB3" ] && [ "$inodeB3" = "$inodeB" ]; then
    for pid in $(docker compose exec -T kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
      if docker compose exec -T kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inodeB3\]'" </dev/null; then
        wpidB3="$wpidB3 $pid"
      fi
    done
  fi
  report "$([ "$inodeB3" = "$inodeB" ] && [ "$wpidB3" = "$wpidB" ] && echo true || echo false)" "B fd5 归属全程一致（inode 同、Worker PID=[$wpidB3] ⇒ 超时请求与后续请求确由同一 Worker 处理，非仅同节点）"
else
  notv "B 同 Worker 归属：Kong 在 503 后关闭了 fd5 客户端连接（inode 消失），无法证明超时请求与后续请求同 Worker——按验收口径标记 NOT VERIFIED"
fi
exec 5>&- 5<&-

printf '\n===== 汇总: PASS=%s FAIL=%s NOT_VERIFIED=%s =====\n' "$PASS" "$FAIL" "$NOTV"
[ "$FAIL" = "0" ]
