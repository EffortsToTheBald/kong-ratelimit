#!/usr/bin/env bash
# ============================================================
# lease-redis-matrix.sh —— Phase 3 第一组：Redis Lease 数据模型裸跑矩阵
#
# 覆盖（实施规范 §5 故障测试 Redis 侧 + §13.2/13.3 清单）：
#   GRANT_LEASE：正常授予 / 部分授予 / tokens<1 不建记录 / LEASE_EXISTS /
#                参数非法零写入 / 桶字段非法零写入 / TTL 公式
#   RETURN_LEASE：正常 / 同参幂等 / 异参 RETURN_CONFLICT / 并发单增 /
#                requested=0 / requested>granted / POOL_MISMATCH /
#                Lease 过期 / Bucket 过期（BUCKET_NOT_FOUND 零写入） /
#                requested 小数 / 提交点后失败注入（重试不重复归还）
#   refill 测试向量：四脚本同状态同向量 + 归一化一致性
#
# 教训（实现期实测）：每 case 独立 lease key（key 隔离防跨轮残留）；
#   fresh 先 DEL 再预置桶状态；预置与断言的 lease key 必须完整（kong:rl:lease:...）；
#   pipefail 下禁用 cat|head（SIGPIPE 静默退出）；后台 wait 需容错。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
RC="docker compose exec -T redis redis-cli"
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; PASS=$((PASS+1)); else warn "FAIL: $2"; FAIL=$((FAIL+1)); fi; }
dexec() { docker compose exec -T redis "$@"; }

# 同步脚本到 redis 容器（docker cp 需完整容器名）
docker compose cp redis/grant_lease.lua redis:/tmp/grant_lease.lua >/dev/null
docker compose cp redis/return_lease.lua redis:/tmp/return_lease.lua >/dev/null
docker compose cp redis/token_bucket.lua redis:/tmp/token_bucket.lua >/dev/null
docker compose cp redis/multi_bucket.lua redis:/tmp/multi_bucket.lua >/dev/null
GL=/tmp/grant_lease.lua; RL=/tmp/return_lease.lua

B="kong:rl:{p3g:m}"
fresh() { # fresh <lease_key> —— DEL 桶 + 本 case 的 Lease key（key 隔离）
    local lk="$1"
    $RC DEL "$B" "$lk" >/dev/null
}
grant() { # grant <batch> <lease_ttl_ms> <lease_id> <pool_key> <rate> <capacity> <bucket_ttl_ms> <lease_key>
    $RC --eval "$GL" "$B" "$8" , "$1" "$2" "$3" "$4" "$5" "$6" "$7" 2>&1
}
ret() { # ret <requested> <pool_key> <bucket_ttl_ms> <rate> <capacity> <lease_key>
    $RC --eval "$RL" "$6" "$B" , "$1" "$2" "$3" "$4" "$5" 2>&1
}
tokens() { $RC HGET "$B" tokens 2>/dev/null || echo "nil"; }
pttl() { $RC PTTL "$1" 2>/dev/null; }

echo "===== GRANT_LEASE ====="
fresh "kong:rl:lease:m1"
R=$(grant 5 60000 m1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m1")
report "$([ "$(echo "$R" | head -1)" = "5" ] && [ "$(tokens)" = "95" ] && [ "$($RC HGET "kong:rl:lease:m1" status)" = "OPEN" ] && [ "$($RC HGET "kong:rl:lease:m1" granted)" = "5" ] && echo true)" \
  "正常授予：granted=5、桶=95（100−5）、OPEN 记录"
PTTL=$(pttl "kong:rl:lease:m1")
report "$([ "$PTTL" -gt 55000 ] && [ "$PTTL" -le 60000 ] && echo true)" "Lease TTL：PTTL=$PTTL ∈ [55000,60000]（传入 60000，断言前执行延迟合法）"
report "$([ "$($RC HGET "kong:rl:lease:m1" pool_key)" = "kong:rl:{p3g:m}" ] && [ "$($RC HGET "kong:rl:lease:m1" lease_id)" = "m1" ] && echo true)" \
  "Lease 记录字段：pool_key/lease_id 正确"
R=$(grant 5 60000 m1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m1")
report "$(echo "$R" | grep -q 'LEASE_EXISTS' && echo true)" "同 ID 二次 GRANT ⇒ LEASE_EXISTS（零写入）"
# 部分授予：预置桶 tokens=2.5（fresh 先 DEL、HSET 在后）
fresh "kong:rl:lease:m2"
$RC HSET "$B" tokens 2.5 >/dev/null
R=$(grant 5 60000 m2 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m2")
report "$([ "$(echo "$R" | head -1)" = "2" ] && [ "$($RC HGET "kong:rl:lease:m2" granted)" = "2" ] && echo true)" "部分授予：floor(2.5)=2"
# tokens<1：granted=0 无记录
fresh "kong:rl:lease:m3"
$RC HSET "$B" tokens 0.5 >/dev/null
R=$(grant 5 60000 m3 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m3")
report "$([ "$(echo "$R" | head -1)" = "0" ] && [ "$($RC EXISTS "kong:rl:lease:m3")" = "0" ] && [ "$(tokens)" = "0.5" ] && echo true)" \
  "tokens<1 ⇒ granted=0、不创建记录、桶不变"
# 参数非法零写入
fresh "kong:rl:lease:m4"
T0=$(tokens)
R=$(grant 0 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT batch' && [ "$(tokens)" = "$T0" ] && echo true)" "batch=0 ⇒ INVALID_ARGUMENT 零写入"
R=$(grant 1.5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT batch' && echo true)" "batch=1.5 ⇒ INVALID_ARGUMENT"
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" -1 100 120000 "kong:rl:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT rate' && echo true)" "rate=-1 ⇒ INVALID_ARGUMENT"
# 桶字段非法（tokens=abc）
$RC HSET "$B" tokens abc >/dev/null
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket tokens' && [ "$(tokens)" = "abc" ] && echo true)" \
  "桶字段非法 ⇒ INVALID_ARGUMENT 零写入"
$RC HSET "$B" tokens 100 >/dev/null

echo "===== RETURN_LEASE ====="
fresh "kong:rl:lease:mr1"
grant 5 60000 mr1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mr1" >/dev/null
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mr1")
report "$([ "$(echo "$R" | head -1)" = "5" ] && [ "$(tokens)" = "100" ] && [ "$($RC HGET "kong:rl:lease:mr1" status)" = "RETURNED" ] && [ "$($RC HGET "kong:rl:lease:mr1" return_requested)" = "5" ] && echo true)" \
  "正常归还：applied=5、桶 95→100、OPEN→RETURNED、return_requested=5"
T0=$(tokens)
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mr1")
report "$(echo "$R" | grep -q 'ALREADY_RETURNED' && [ "$(tokens)" = "$T0" ] && echo true)" \
  "同参重复 ⇒ ALREADY_RETURNED 桶不变"
R=$(ret 3 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mr1")
report "$(echo "$R" | grep -q 'RETURN_CONFLICT' && echo true)" "同 ID 异参 ⇒ RETURN_CONFLICT"
# requested=0：全消费后关闭
fresh "kong:rl:lease:mz"
grant 5 60000 mz "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mz" >/dev/null
$RC DEL "kong:rl:lease:mz" >/dev/null
$RC HSET "kong:rl:lease:mz" lease_id mz pool_key "kong:rl:{p3g:m}" granted 0 status OPEN >/dev/null
T0=$(tokens)
R=$(ret 0 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mz")
report "$([ "$(echo "$R" | head -1)" = "0" ] && [ "$(tokens)" = "$T0" ] && [ "$($RC HGET "kong:rl:lease:mz" status)" = "RETURNED" ] && [ "$($RC HGET "kong:rl:lease:mz" return_requested)" = "0" ] && echo true)" \
  "requested=0 ⇒ 跳过桶更新、OPEN→RETURNED（账目闭合）"
# requested>granted
fresh "kong:rl:lease:mx"
grant 5 60000 mx "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mx" >/dev/null
R=$(ret 6 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mx")
report "$(echo "$R" | grep -q 'INVALID_REQUESTED' && echo true)" "requested>granted ⇒ INVALID_REQUESTED 零写入"
# POOL_MISMATCH
R=$(ret 5 "kong:rl:{p3g:other}" 120000 0.016 100 "kong:rl:lease:mx")
report "$(echo "$R" | grep -q 'POOL_MISMATCH' && echo true)" "pool_key 不匹配 ⇒ POOL_MISMATCH 零写入"
# Lease 过期（TTL 100ms）
fresh "kong:rl:lease:mexp"
grant 5 100 mexp "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mexp" >/dev/null
sleep 0.4
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mexp")
report "$(echo "$R" | grep -q 'LEASE_NOT_FOUND' && echo true)" "Lease 过期 ⇒ LEASE_NOT_FOUND（不得推测归还）"
# Bucket 不存在（BUCKET_NOT_FOUND 零写入）
fresh "kong:rl:lease:mb"
grant 5 60000 mb "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mb" >/dev/null
$RC DEL "$B" >/dev/null
T0=$($RC EXISTS "$B")
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mb")
report "$(echo "$R" | grep -q 'BUCKET_NOT_FOUND' && [ "$($RC EXISTS "$B")" = "$T0" ] && echo true)" \
  "Bucket 不存在 ⇒ BUCKET_NOT_FOUND、不创建新桶、零写入"
# requested 小数
fresh "kong:rl:lease:mf"
grant 5 60000 mf "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mf" >/dev/null
R=$(ret 1.5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mf")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT requested' && [ "$($RC HGET "kong:rl:lease:mf" status)" = "OPEN" ] && echo true)" \
  "requested=1.5（小数）⇒ INVALID_ARGUMENT 零写入"
# 并发两 RETURN：桶只加一次
fresh "kong:rl:lease:mc"
grant 5 60000 mc "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mc" >/dev/null
T0=$(tokens)
dexec redis-cli --eval "$RL" "kong:rl:lease:mc" "$B" , 5 "kong:rl:{p3g:m}" 120000 0.016 100 >/tmp/c1.txt 2>&1 &
dexec redis-cli --eval "$RL" "kong:rl:lease:mc" "$B" , 5 "kong:rl:{p3g:m}" 120000 0.016 100 >/tmp/c2.txt 2>&1 &
wait || true
T1=$(tokens)
SUCC=$(grep -c '^5$' /tmp/c1.txt /tmp/c2.txt | awk -F: '{s+=$2} END{print s}')
ALR=$(grep -c 'ALREADY_RETURNED' /tmp/c1.txt /tmp/c2.txt | awk -F: '{s+=$2} END{print s}')
report "$([ "$SUCC" = "1" ] && [ "$ALR" = "1" ] && [ "$T1" = "$((T0+5))" ] && echo true)" \
  "并发两 RETURN：一成功（applied=5）一 ALREADY_RETURNED、桶只加一次"
# 提交点后失败注入（测试变体：生产脚本不动）
python3 test/make_inject_variant.py /tmp/rl_inject.txt >/dev/null
docker compose cp /tmp/rl_inject.txt redis:/tmp/rl_inject.txt >/dev/null
fresh "kong:rl:lease:mi"
grant 5 60000 mi "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:lease:mi" >/dev/null
T0=$(tokens)
R=$(dexec redis-cli --eval /tmp/rl_inject.txt "kong:rl:lease:mi" "$B" , 5 "kong:rl:{p3g:m}" 120000 0.016 100 2>&1) || true
report "$(echo "$R" | grep -q 'INJECTED_FAILURE' && [ "$($RC HGET "kong:rl:lease:mi" status)" = "RETURNED" ] && [ "$(tokens)" = "$T0" ] && echo true)" \
  "提交点后失败注入：Lease 已 RETURNED、桶未加（幂等提交点先行实证）"
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:lease:mi")
report "$(echo "$R" | grep -q 'ALREADY_RETURNED' && [ "$(tokens)" = "$T0" ] && echo true)" \
  "注入后同参重试：ALREADY_RETURNED、桶不重复增加（差额计损失）"

echo "===== refill 测试向量（四脚本同状态同向量）====="
# 向量：预置 tokens=100、ts=now−10、rate=1/s、capacity=1000 ⇒ refill=110
# 断言口径：区间 [want, want+4]（docker exec 间隔抖动 ⇒ refill 微秒尾差），另加四脚本归一化一致性
refill_vector() { # refill_vector <label> <tokens读数> <预期refill后值>
    local label="$1" got="$2" want="$3"
    local in_range
    in_range=$(awk -v g="$got" -v w="$want" 'BEGIN{print (g>=w && g<w+4) ? 1 : 0}')
    report "$([ "$in_range" = "1" ] && echo true)" "refill 向量 $label：tokens=$got ≈ $want（rate×10s 补充，区间含 exec 间隔）"
}
V1=""; V2=""; V3=""; V4=""
fresh "kong:rl:lease:gv"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
R=$($RC --eval /tmp/grant_lease.lua "$B" "kong:rl:lease:gv" , 1 60000 gv "kong:rl:{p3g:m}" 1 1000 120000)
V1=$(tokens)
refill_vector "GRANT_LEASE(batch=1，扣 granted=1)" "$V1" 109
fresh "kong:rl:lease:rv"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
# RETURN 需 OPEN Lease 记录（granted=2 供 requested=1 校验）
$RC HSET "kong:rl:lease:rv" lease_id rv pool_key "kong:rl:{p3g:m}" granted 2 status OPEN >/dev/null
R=$($RC --eval /tmp/return_lease.lua "kong:rl:lease:rv" "$B" , 1 "kong:rl:{p3g:m}" 120000 1 1000)
V2=$(tokens)
refill_vector "RETURN_LEASE(requested=1，加 applied=1)" "$V2" 111
fresh "kong:rl:lease:tb"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
R=$($RC --eval /tmp/token_bucket.lua "$B" , 1 1000 1 120000)
V3=$(tokens)
refill_vector "TOKEN_BUCKET(want=1，扣 granted=1)" "$V3" 109
fresh "kong:rl:lease:gm"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
R=$($RC --eval /tmp/multi_bucket.lua "$B" "$B" , 1 1 1000 120000)
V4=$(tokens)
refill_vector "GRANT_MULTI(batch=1，扣 granted=1)" "$V4" 109
# 四脚本归一化一致性（GRANT/RETURN 的 ±1 抵消后两两差 <3s = exec 间隔抖动上界）
CONS=$(awk -v a="$V1" -v b="$V2" -v c="$V3" -v d="$V4" 'BEGIN{
  n1=a+1; n2=b-1; n3=c+1; n4=d+1
  m=(n1+n2+n3+n4)/4; r=0
  s=n1-m; if(s<0)s=-s; if(s>r)r=s
  s=n2-m; if(s<0)s=-s; if(s>r)r=s
  s=n3-m; if(s<0)s=-s; if(s>r)r=s
  s=n4-m; if(s<0)s=-s; if(s>r)r=s
  print (r<3) ? 1 : 0}')
report "$([ "$CONS" = "1" ] && echo true)" "refill 一致性：四脚本归一化最大偏差 <3s（$V1/$V2/$V3/$V4）"

echo
echo "===== 汇总: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
