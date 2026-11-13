#!/usr/bin/env bash
# ============================================================
# algorithm-lease-unit.sh —— 6.1 接线单测：三模式行为矩阵（resty）
#
# 覆盖：batch=1 零 Lease / batch>1 GRANT→登记→恰好消费 1 / 本地 TAKE
#       不重复访问 Redis / 耗尽 CLOSED+再申请（并存不覆盖）/ 部分授予 /
#       granted=0 ⇒ 429 / explicit_error、uncertain ⇒ 故障分支 /
#       指纹隔离 / 多规则 GRANT_MULTI 零 Lease
# 运行：docker compose cp + kong1 内 resty 执行（与 lease-unit.sh 同模式）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose cp test/algorithm-lease-unit.lua kong1:/tmp/algorithm-lease-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/algorithm-lease-unit.lua
