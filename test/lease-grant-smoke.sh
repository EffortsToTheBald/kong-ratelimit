#!/usr/bin/env bash
# ============================================================
# lease-grant-smoke.sh —— GRANT 接线真链路 smoke（任务 4.4）
#
# Case 1：真 Redis EVALSHA GRANT_LEASE ⇒ 建本地 Lease/消费/Redis 证据
# Case 2：CLIENT PAUSE 2500ms + 客户端 timeout 500ms ⇒ 超时 uncertain：
#         不重试（耗时 < 2×timeout）、不登记本地库存；pause 过期后
#         验证 Redis 侧已执行（桶已扣 + Lease 记录 OPEN）⇒ 库存损失方向
# 注意：Case 2 会短暂暂停 Redis 客户端命令 2.5s（测试窗口内自愈）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose cp test/lease-grant-smoke.lua kong1:/tmp/lease-grant-smoke.lua >/dev/null

echo "--- Case 1: normal grant ---"
docker compose exec -T kong1 resty /tmp/lease-grant-smoke.lua

echo "--- Case 2: client pause (uncertain) ---"
# 脚本启动后先 warm-up（装载脚本 SHA，约 1-2s），故 pause 在 sleep 后施加，
# 且窗口足够覆盖（8s）；脚本内轮询探测 pause 生效后再实测
docker compose exec -T -e PAUSE=1 -e REDIS_TIMEOUT=500 -e PAUSE_MS=8000 kong1 resty /tmp/lease-grant-smoke.lua &
SCRIPT_PID=$!
sleep 2.5
docker compose exec -T redis redis-cli CLIENT PAUSE 8000 >/dev/null
wait $SCRIPT_PID
