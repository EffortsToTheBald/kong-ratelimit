#!/usr/bin/env bash
# ============================================================
# lease-isolation.sh —— 多 Worker 隔离验证（任务 4.5）
#
# 原理：OpenResty 每 Worker 独立 Lua VM ⇒ 模块级 table 按 Worker 隔离
#       （design 事实 6，1.2 已实证）。本脚本以两个独立 resty 进程
#       代表两个 Worker：相同 pool_key 下各自登记 Lease，
#       验证 ① 各进程只可见自己的 Lease（互不可见）
#            ② TAKE 只消费自己的 Lease（互不代管）
#            ③ 进程内 require 单例（跨请求共享 = Worker 级语义）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose cp test/lease-iso.lua kong1:/tmp/lease-iso.lua >/dev/null

PASS=0; FAIL=0
check() { # check <name> <cond> <detail>
    if [ "$2" = "1" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL [$1] $3"; fi
}

A=$(docker compose exec -T -e ISO_ID=workerA kong1 resty /tmp/lease-iso.lua)
B=$(docker compose exec -T -e ISO_ID=workerB kong1 resty /tmp/lease-iso.lua)

echo "--- VM A ---"; echo "$A"
echo "--- VM B ---"; echo "$B"

check "A-sees-only-A"      "$(echo "$A" | grep -q 'leases=lease-workerA' && echo 1 || echo 0)" "$A"
check "A-no-B-visibility"  "$(echo "$A" | grep -q 'workerB' && echo 0 || echo 1)" "$A"
check "B-sees-only-B"      "$(echo "$B" | grep -q 'leases=lease-workerB' && echo 1 || echo 0)" "$B"
check "B-no-A-visibility"  "$(echo "$B" | grep -q 'workerA' && echo 0 || echo 1)" "$B"
check "A-take-own-lease"   "$(echo "$A" | grep -q 'TAKE=lease-workerA expected=lease-workerA' && echo 1 || echo 0)" "$A"
check "B-take-own-lease"   "$(echo "$B" | grep -q 'TAKE=lease-workerB expected=lease-workerB' && echo 1 || echo 0)" "$B"
check "singleton-per-vm"   "$(echo "$A" | grep -q 'SINGLETON-BROKEN' && echo 0 || echo 1)" "$A"

echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
