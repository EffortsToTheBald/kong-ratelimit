#!/usr/bin/env bash
# ============================================================
# config-isolation-unit.sh —— 6.3 配置隔离单测（resty）
# 覆盖：五维度指纹隔离矩阵（实际 build_key）/ batch 不入指纹 /
#       pool_key=桶键一体格式 / 本地 Pool 隔离（A 库存不被 B 消费、
#       B 独立 GRANT、A 库存独立存活、相同配置命中同 Pool）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose cp test/config-isolation-unit.lua kong1:/tmp/config-isolation-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/config-isolation-unit.lua
