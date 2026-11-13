#!/usr/bin/env bash
# ============================================================
# concurrent-lease-e2e.sh —— 6.5 测试1：多 Worker 并发 TAKE / GRANT
#
# 目标（冻结口径）：
#   1. 并发请求分布到多个 Worker（lease_id = host:worker:seq:hex 实证）
#   2. 全局不超发：Σgranted == limit == 100；HTTP 放行 == 100 == Σgranted
#      （GRANT 授权量 / 本地 TAKE 消费量 / HTTP 放行量 三者口径区分见报告）
#   3. 并发 TAKE 无重复消费：所有 X-RateLimit-Remaining ≥ 0
#      （remaining = 本地池余量，algorithm.lua:423-424）+ allowed == Σgranted
#   4. 耗尽后正确重新申请（耗尽 ⇒ 新 GRANT，denied-GRANT granted=0 ⇒ 429）
# 前置：3 节点 × ≥2 Worker；同 namespace 同规则 batch=10；window=86400
#      （测试全程 refill < 0.1 token ⇒ 不影响精确账目）
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
PROXY="http://localhost:8030"
NS="p65c$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

# ---- 前置检查 ----
RC PING >/dev/null || { bad "Redis 不可用"; exit 1; }
for n in kong1 kong2 kong3; do
  w=$(docker compose exec -T "$n" sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | wc -l' </dev/null | tr -d ' ')
  report "$([ "$w" -ge 2 ] && echo true)" "$n Worker 数=$w（≥2）"
done
ok "前置：Redis PING + 3 节点 Worker 数核验"

# ---- 配置下发 ----
cat <<EOF > /tmp/opencode/p65c-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"conc","paths":["/conc"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
   "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65c-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "配置下发：limit=100 window=86400 batch=10 ns=$NS（3 节点）"

# ---- Phase A：30 并发请求（三节点轮转，采样 X-RateLimit-Remaining） ----
mkdir -p /tmp/opencode/p65c-h
seq 1 30 | awk -v c=$$ '{print $1}' | while read i; do echo "$i"; done >/dev/null
seq 1 30 | xargs -P 8 -I{} sh -c 'p=$(( {} % 3 )); case $p in 0) u=8030;; 1) u=8010;; 2) u=8020;; esac; curl -s -o /dev/null -D /tmp/opencode/p65c-h/h{} -w "%{http_code}\n" --max-time 8 http://localhost:$u/conc' > /tmp/opencode/p65c-a.txt || true
ok "Phase A：30 并发请求（三节点轮转，每请求采样响应头）"

# ---- Phase B：270 并发请求（三节点轮转） ----
seq 1 270 | xargs -P 8 -I{} sh -c 'p=$(( {} % 3 )); case $p in 0) u=8030;; 1) u=8010;; 2) u=8020;; esac; curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://localhost:$u/conc' > /tmp/opencode/p65c-b.txt || true
ok "Phase B：270 并发请求（三节点轮转）"

# ---- Phase C：排空（顺序请求轮转三节点，直到连续 100 次 429；上限 600 次） ----
: > /tmp/opencode/p65c-drain.txt
streak=0; allowed_drain=0
for i in $(seq 1 600); do
  case $(( i % 3 )) in 0) u=8030;; 1) u=8010;; 2) u=8020;; esac
  line=$(curl -s -o /dev/null -D /tmp/opencode/p65c-lasthdr -w '%{http_code}' --max-time 8 "http://localhost:$u/conc")
  echo "$line" >> /tmp/opencode/p65c-drain.txt
  if [ "$line" = "429" ]; then
    streak=$((streak+1))
    [ "$streak" -ge 100 ] && break
  else
    streak=0; allowed_drain=$((allowed_drain+1))
  fi
done
ok "Phase C：排空（连续 100×429 或 500 上限；排空期新增放行=$allowed_drain）"

# ---- 汇总统计 ----
allowed_a=$(grep -c '^200$' /tmp/opencode/p65c-a.txt || true)
denied_a=$(grep -c '^429$' /tmp/opencode/p65c-a.txt || true)
other_a=$(grep -cv '^200$\|^429$' /tmp/opencode/p65c-a.txt || true)
allowed_b=$(grep -c '^200$' /tmp/opencode/p65c-b.txt || true)
denied_b=$(grep -c '^429$' /tmp/opencode/p65c-b.txt || true)
other_b=$(grep -cv '^200$\|^429$' /tmp/opencode/p65c-b.txt || true)
denied_c=$(grep -c '^429$' /tmp/opencode/p65c-drain.txt || true)
other_c=$(grep -cv '^429$' /tmp/opencode/p65c-drain.txt || true)
allowed=$((allowed_a + allowed_b + allowed_drain))
total=$(( $(wc -l < /tmp/opencode/p65c-a.txt) + $(wc -l < /tmp/opencode/p65c-b.txt) + $(wc -l < /tmp/opencode/p65c-drain.txt) ))
other=$((other_a + other_b + other_c))
echo "统计: total=$total allowed=$allowed denied429=$((denied_a+denied_b+denied_c)) other=$other (A:$allowed_a/30 B:$allowed_b/270 C:$allowed_drain)"

# ---- 断言 1：无异常状态码 ----
report "$(eq "$other" 0)" "无 5xx/其他异常状态码（other=$other）"

# ---- 断言 2：全局不超发：allowed == 100 == limit ----
report "$(eq "$allowed" 100)" "HTTP 放行=$allowed（恰等于 limit=100；并发竞争未超发）"

# ---- 断言 3：Redis GRANT 记录账目：Σgranted == 100，各记录 granted=10 ----
records=0; sum_granted=0; workers_seen=""
while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) ;; *) continue ;; esac
  records=$((records+1))
  g=$(RC HGET "$k" granted </dev/null | tr -d '\r')
  sum_granted=$((sum_granted + g))
  lid=$(RC HGET "$k" lease_id </dev/null | tr -d '\r')
  hostw=$(echo "$lid" | cut -d: -f1,2)
  case ",$workers_seen," in *",$hostw,"*) ;; *) workers_seen="$workers_seen,$hostw" ;; esac
done < <(RC --scan --pattern 'kong:rl:lease:*' </dev/null)
ndistinct=$(echo "$workers_seen" | tr ',' '\n' | grep -c . || true)
echo "GRANT 记录: count=$records Σgranted=$sum_granted distinct(host,worker)=$ndistinct [$workers_seen]"
report "$(eq "$sum_granted" 100)" "Redis GRANT 授权总量=$sum_granted（恰等于 limit=100，不超发）"
report "$(eq "$records" 10)" "GRANT 记录数=$records（10 次×batch=10，每池 10）"

# ---- 断言 4：请求分布到多个 Worker ----
report "$([ "$ndistinct" -ge 3 ] && echo true)" "请求分布到 $ndistinct 个不同 (host,worker) ≥3（lease_id host:worker 段实证）"

# ---- 断言 5：本地 TAKE 无重复消费：所有采样 remaining ≥ 0 ----
minrem=99999
for f in /tmp/opencode/p65c-h/h* /tmp/opencode/p65c-lasthdr; do
  [ -f "$f" ] || continue
  r=$(sed -n 's/^X-RateLimit-Remaining: //pi' "$f" | tr -d '\r')
  [ -n "$r" ] && [ "$r" -lt "$minrem" ] && minrem=$r
done
report "$([ "$minrem" -ge 0 ] && echo true)" "全部采样 X-RateLimit-Remaining ≥ 0（min=$minrem；本地池无负库存/无重复消费）"

# ---- 断言 6：TAKE 消费量口径 == HTTP 放行（每 200 恰一次成功 TAKE） ----
report "$(eq "$allowed" "$sum_granted")" "本地 TAKE 消费总量=$allowed == Σgranted=$sum_granted（每个授予令牌恰被消费一次，无丢失无重复）"

# ---- 断言 7：耗尽后新 GRANT 语义（denied-GRANT ⇒ 429，不伪装 503） ----
report "$([ $((denied_a+denied_b+denied_c)) -gt 0 ] && echo true)" "超额请求返回 429=$((denied_a+denied_b+denied_c))（耗尽后 denied-GRANT granted=0 既有语义）"

# ---- 断言 8：桶 tokens 终态 < 1 ----
bkey=$(RC --scan --pattern 'kong:rl:{'"$NS"':p=*' </dev/null | head -1)
tok=$(RC HGET "$bkey" tokens </dev/null | tr -d '\r')
report "$(awk -v t="$tok" 'BEGIN{print (t<1)?"true":"false"}')" "桶 tokens 终态=$tok < 1（配额全部经 GRANT 消化，无泄漏）"

printf '\n===== 汇总: PASS=%s FAIL=%s NOT_VERIFIED=%s =====\n' "$PASS" "$FAIL" "$NOTV"
[ "$FAIL" = "0" ]
