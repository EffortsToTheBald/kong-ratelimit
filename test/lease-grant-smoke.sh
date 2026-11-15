#!/usr/bin/env bash
# ============================================================
# lease-grant-smoke.sh —— real-path smoke of GRANT wiring (task 4.4)
#
# Case 1: real Redis EVALSHA GRANT_LEASE ⇒ local Lease created / consumption / Redis evidence
# Case 2: CLIENT PAUSE 2500ms + client timeout 500ms ⇒ timeout uncertain:
#         no retry (elapsed < 2x timeout), no registration in local lease pool; after pause
#         expires, verify Redis side executed (bucket debited + Lease record OPEN) ⇒ direction of stock loss
# Note: Case 2 briefly pauses Redis client commands for 2.5s (self-heals within the test window)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose cp test/lease-grant-smoke.lua kong1:/tmp/lease-grant-smoke.lua >/dev/null

echo "--- Case 1: normal grant ---"
docker compose exec -T kong1 resty /tmp/lease-grant-smoke.lua

echo "--- Case 2: client pause (uncertain) ---"
# After startup the script warms up first (loading script SHAs, ~1-2s), so pause is applied after the sleep,
# and the window is wide enough (8s); the script polls to detect pause is active before the real measurement
docker compose exec -T -e PAUSE=1 -e REDIS_TIMEOUT=500 -e PAUSE_MS=8000 kong1 resty /tmp/lease-grant-smoke.lua &
SCRIPT_PID=$!
sleep 2.5
docker compose exec -T redis redis-cli CLIENT PAUSE 8000 >/dev/null
wait $SCRIPT_PID
