#!/usr/bin/env bash
# ============================================================
# lease-unit.sh —— lib/lease.lua 的 resty 协议级单测（任务 4.1–4.4）
#
# 覆盖：register 字段/守恒/参数拒绝、TAKE 递减/插入序/多 Lease 并存/
#       无 yield 探针/随机序列结构不变量、耗尽 CLOSED/摘除/保留诊断/
#       不可复活、GRANT 四分类（成功/不足/明确错误/不确定不重试不登记）/
#       lease_id 唯一性、V1 账目恒等式
# 运行：docker compose cp + kong1 内 resty 执行（与 evalsha-unit.sh 同模式）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose cp test/lease-unit.lua kong1:/tmp/lease-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/lease-unit.lua
