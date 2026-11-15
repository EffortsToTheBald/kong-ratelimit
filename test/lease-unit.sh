#!/usr/bin/env bash
# ============================================================
# lease-unit.sh —— resty protocol-level unit tests for lib/lease.lua (tasks 4.1–4.4)
#
# Coverage: register fields/conservation/parameter rejection, TAKE decrement/insertion
#           order/multi-Lease coexistence, no-yield probe/random-sequence structural
#           invariants, exhaustion CLOSED/removal/retained diagnostics/no revival,
#           GRANT four-way classification (success/insufficient/explicit error/uncertain
#           with no retry and no registration), lease_id uniqueness, V1 accounting identity
# Run: docker compose cp + resty inside kong1 (same pattern as evalsha-unit.sh)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
docker compose cp test/lease-unit.lua kong1:/tmp/lease-unit.lua >/dev/null
docker compose exec -T kong1 resty /tmp/lease-unit.lua
