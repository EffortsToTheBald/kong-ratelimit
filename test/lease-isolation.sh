#!/usr/bin/env bash
# ============================================================
# lease-isolation.sh —— multi-Worker isolation verification (task 4.5)
#
# Principle: OpenResty has an independent Lua VM per Worker ⇒ module-level tables are
#            isolated per Worker (design fact 6, proven in 1.2). This script uses two
#            independent resty processes to represent two Workers: each registers its
#            own Lease under the same pool_key, and verifies that
#            ① each process only sees its own Lease (invisible to each other)
#            ② TAKE only consumes its own Lease (no managing on each other's behalf)
#            ③ in-process require singleton (cross-request sharing = Worker-level semantics)
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
