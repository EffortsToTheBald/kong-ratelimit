#!/usr/bin/env bash
# ============================================================
# algorithm-lease-unit.sh —— 6.1 wiring unit tests: three-mode behavior matrix (resty)
#
# Coverage: batch=1 zero Lease / batch>1 GRANT->register->exactly 1 consumed / local TAKE
#           without repeated Redis access / exhaustion CLOSED+re-request (coexistence without
#           overwrite) / partial grant / granted=0 ⇒ 429 / explicit_error and uncertain ⇒ fault
#           branch / fingerprint isolation / multi-rule GRANT_MULTI zero Lease
# Run: docker compose cp + resty inside kong1 (same pattern as lease-unit.sh)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose cp test/algorithm-lease-unit.lua kong1:/tmp/algorithm-lease-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/algorithm-lease-unit.lua
