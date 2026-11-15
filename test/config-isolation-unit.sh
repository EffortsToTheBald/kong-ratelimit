#!/usr/bin/env bash
# ============================================================
# config-isolation-unit.sh —— 6.3 config isolation unit tests (resty)
# Coverage: five-dimension fingerprint isolation matrix (actual build_key) / batch not in the fingerprint /
#       pool_key=bucket-key unified format / local Pool isolation (A's stock not consumed by B,
#       B grants independently, A's stock survives independently, identical config hits the same Pool)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose cp test/config-isolation-unit.lua kong1:/tmp/config-isolation-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/config-isolation-unit.lua
