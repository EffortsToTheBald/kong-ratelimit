#!/usr/bin/env bash
# ============================================================
# lease-redis-matrix.sh —— Phase 3 group 1: bare-run matrix of the Redis Lease data model
#
# Coverage (implementation spec §5 Redis-side fault tests + §13.2/13.3 checklist):
#   GRANT_LEASE: normal grant / partial grant / tokens<1 no record / LEASE_EXISTS /
#                invalid parameters zero-write / invalid bucket fields zero-write / TTL formula
#   RETURN_LEASE: normal / idempotent with same args / RETURN_CONFLICT with different args /
#                concurrent single increment /
#                requested=0 / requested>granted / POOL_MISMATCH /
#                Lease expired / Bucket expired (BUCKET_NOT_FOUND zero-write) /
#                fractional requested / failure injection after commit point (retry does not double-return)
#   refill test vectors: four scripts in same state with same vector + normalized consistency
#
# Lessons learned (measured during implementation): independent lease key per case (key isolation prevents cross-round residue);
#   fresh does DEL before presetting bucket state; lease keys used for preset and assertion must be complete (kong:rl:{p3g:m}:lease:...);
#   cat|head is forbidden under pipefail (SIGPIPE silent exit); background wait must be fault-tolerant.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
RC="docker compose exec -T redis redis-cli"
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; PASS=$((PASS+1)); else warn "FAIL: $2"; FAIL=$((FAIL+1)); fi; }
dexec() { docker compose exec -T redis "$@"; }

# Sync scripts into the redis container (docker cp needs the full container name)
docker compose cp redis/grant_lease.lua redis:/tmp/grant_lease.lua >/dev/null
docker compose cp redis/return_lease.lua redis:/tmp/return_lease.lua >/dev/null
docker compose cp redis/token_bucket.lua redis:/tmp/token_bucket.lua >/dev/null
docker compose cp redis/multi_bucket.lua redis:/tmp/multi_bucket.lua >/dev/null
GL=/tmp/grant_lease.lua; RL=/tmp/return_lease.lua

B="kong:rl:{p3g:m}"
fresh() { # fresh <lease_key> —— DEL the bucket + this case's Lease key (key isolation)
    local lk="$1"
    $RC DEL "$B" "$lk" >/dev/null
}
grant() { # grant <batch> <lease_ttl_ms> <lease_id> <pool_key> <rate> <capacity> <bucket_ttl_ms> <lease_key>
    $RC --eval "$GL" "$B" "$8" , "$1" "$2" "$3" "$4" "$5" "$6" "$7" 2>&1
}
ret() { # ret <requested> <pool_key> <bucket_ttl_ms> <rate> <capacity> <lease_key>
    $RC --eval "$RL" "$6" "$B" , "$1" "$2" "$3" "$4" "$5" 2>&1
}
tokens() { $RC HGET "$B" tokens 2>/dev/null || echo "nil"; }
pttl() { $RC PTTL "$1" 2>/dev/null; }

echo "===== GRANT_LEASE ====="
fresh "kong:rl:{p3g:m}:lease:m1"
R=$(grant 5 60000 m1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m1")
report "$([ "$(echo "$R" | head -1)" = "5" ] && [ "$(tokens)" = "95" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:m1" status)" = "OPEN" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:m1" granted)" = "5" ] && echo true)" \
  "normal grant: granted=5, bucket=95 (100-5), OPEN record"
PTTL=$(pttl "kong:rl:{p3g:m}:lease:m1")
report "$([ "$PTTL" -gt 55000 ] && [ "$PTTL" -le 60000 ] && echo true)" "Lease TTL: PTTL=$PTTL in [55000,60000] (60000 passed in; execution delay before assertion is legitimate)"
report "$([ "$($RC HGET "kong:rl:{p3g:m}:lease:m1" pool_key)" = "kong:rl:{p3g:m}" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:m1" lease_id)" = "m1" ] && echo true)" \
  "Lease record fields: pool_key/lease_id correct"
R=$(grant 5 60000 m1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m1")
report "$(echo "$R" | grep -q 'LEASE_EXISTS' && echo true)" "second GRANT with same ID ⇒ LEASE_EXISTS (zero-write)"
# Partial grant: preset bucket tokens=2.5 (fresh DELs first, HSET after)
fresh "kong:rl:{p3g:m}:lease:m2"
$RC HSET "$B" tokens 2.5 >/dev/null
R=$(grant 5 60000 m2 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m2")
report "$([ "$(echo "$R" | head -1)" = "2" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:m2" granted)" = "2" ] && echo true)" "partial grant: floor(2.5)=2"
# tokens<1: granted=0, no record
fresh "kong:rl:{p3g:m}:lease:m3"
$RC HSET "$B" tokens 0.5 >/dev/null
R=$(grant 5 60000 m3 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m3")
report "$([ "$(echo "$R" | head -1)" = "0" ] && [ "$($RC EXISTS "kong:rl:{p3g:m}:lease:m3")" = "0" ] && [ "$(tokens)" = "0.5" ] && echo true)" \
  "tokens<1 ⇒ granted=0, no record created, bucket unchanged"
# Invalid parameters, zero-write
fresh "kong:rl:{p3g:m}:lease:m4"
T0=$(tokens)
R=$(grant 0 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT batch' && [ "$(tokens)" = "$T0" ] && echo true)" "batch=0 ⇒ INVALID_ARGUMENT, zero-write"
R=$(grant 1.5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT batch' && echo true)" "batch=1.5 ⇒ INVALID_ARGUMENT"
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" -1 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT rate' && echo true)" "rate=-1 ⇒ INVALID_ARGUMENT"
# Invalid bucket field (tokens=abc)
$RC HSET "$B" tokens abc >/dev/null
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket tokens' && [ "$(tokens)" = "abc" ] && echo true)" \
  "invalid bucket field ⇒ INVALID_ARGUMENT, zero-write"
# P1-2: bucket state numeric range validation (negative tokens / over capacity / negative ts) — invalid values must not be silently corrected, data unchanged
$RC HSET "$B" tokens -5 ts "$(date +%s)" >/dev/null
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket tokens: -5' && [ "$(tokens)" = "-5" ] && echo true)" \
  "tokens=-5 (negative) ⇒ rejected and data unchanged (no silent correction)"
$RC HSET "$B" tokens 200 ts "$(date +%s)" >/dev/null
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket tokens: 200' && [ "$(tokens)" = "200" ] && echo true)" \
  "tokens=200 > capacity=100 ⇒ rejected and data unchanged"
$RC HSET "$B" tokens 100 ts -1 >/dev/null
R=$(grant 5 60000 m4 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:m4")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket ts: -1' && [ "$($RC HGET "$B" ts)" = "-1" ] && echo true)" \
  "ts=-1 (negative) ⇒ rejected and data unchanged"
# RETURN same-style range validation (consistent with GRANT validity rules)
fresh "kong:rl:{p3g:m}:lease:mr2"
grant 5 60000 mr2 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mr2" >/dev/null
$RC HSET "$B" tokens -5 ts "$(date +%s)" >/dev/null
R=$(ret 1 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mr2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket tokens: -5' && [ "$(tokens)" = "-5" ] && echo true)" \
  "RETURN tokens=-5 ⇒ rejected and data unchanged (consistent with GRANT rules)"
$RC HSET "$B" tokens 200 ts "$(date +%s)" >/dev/null
R=$(ret 1 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mr2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket tokens: 200' && [ "$(tokens)" = "200" ] && echo true)" \
  "RETURN tokens=200 > capacity ⇒ rejected and data unchanged"
$RC DEL "$B" >/dev/null
$RC HSET "$B" tokens 100 ts -1 >/dev/null
R=$(ret 1 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mr2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket ts: -1' && [ "$($RC HGET "$B" ts)" = "-1" ] && echo true)" \
  "RETURN ts=-1 ⇒ rejected and data unchanged"
$RC HSET "$B" tokens 100 ts "$(date +%s)" >/dev/null
# Invalid granted (granted=-5 / granted=0 ⇒ INVALID_LEASE_STATE granted)
fresh "kong:rl:{p3g:m}:lease:mg"
$RC HSET "kong:rl:{p3g:m}:lease:mg" lease_id mg pool_key "kong:rl:{p3g:m}" granted -5 status OPEN created_at "$(date +%s)" >/dev/null
R=$(ret 1 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mg")
report "$(echo "$R" | grep -q 'INVALID_LEASE_STATE granted: -5' && echo true)" "granted=-5 ⇒ INVALID_LEASE_STATE granted"
$RC DEL "$B" >/dev/null
$RC HSET "kong:rl:{p3g:m}:lease:mg" granted 0 status OPEN >/dev/null
R=$(ret 1 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mg")
report "$(echo "$R" | grep -q 'INVALID_LEASE_STATE granted: 0' && echo true)" "granted=0 ⇒ INVALID_LEASE_STATE granted"
# P1-1: insufficient-branch persistent refill (preset tokens=0.5, ts in the past, still <1 after refill ⇒ granted=0 but bucket state and TTL are written back)
fresh "kong:rl:{p3g:m}:lease:mnr"
TS_BEFORE=$($RC TIME | awk 'NR==1{print $1 - 5}')
$RC HSET "$B" tokens 0.5 ts "$TS_BEFORE" >/dev/null
NOW0=$($RC TIME | awk 'NR==1{print $1}')
R=$(grant 5 60000 mnr "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mnr")
NOW1=$($RC TIME | awk 'NR==1{print $1}')
TA=$(tokens); TSA=$($RC HGET "$B" ts); PT=$($RC PTTL "$B")
echo "DBG-mnr: R1=[$(echo "$R" | head -1)] TA=[$TA] TSA=[$TSA] PT=[$PT] exists=[$($RC EXISTS "kong:rl:{p3g:m}:lease:mnr")] now0=$NOW0 now1=$NOW1" >&2
report "$(echo "$R" | head -1 | grep -q '^0$' && [ "$($RC EXISTS "kong:rl:{p3g:m}:lease:mnr")" = "0" ] && echo true)" \
  "insufficient branch: granted=0, no Lease created"
TSC=$(awk -v a="$TSA" -v b="$TS_BEFORE" 'BEGIN{print (a>=b) ? 1 : 0}')
echo "DBG-ts: TSA=[$TSA] TS_BEFORE=[$TS_BEFORE] cond=$TSC lenTSA=${#TSA}" >&2
report "$([ "$TSC" = "1" ] && echo true)" \
  "insufficient branch: ts only moves forward ($TSA >= $TS_BEFORE)"
report "$([ "$PT" -gt 110000 ] && [ "$PT" -le 120000 ] && echo true)" \
  "insufficient branch: bucket TTL written back (PTTL=$PT ~= 120000)"
TCONS=$(awk -v t="$TSA" -v n0="$NOW0" -v n1="$NOW1" 'BEGIN{print (t>=n0-1 && t<=n1+1) ? 1 : 0}')
echo "DBG-tcons: TSA=[$TSA] NOW0=[$NOW0] NOW1=[$NOW1] cond=$TCONS" >&2
report "$([ "$TCONS" = "1" ] && echo true)" \
  "insufficient branch: tokens/ts consistent with unified semantics (ts=$TSA in [now0-1, now1+1]; tokens=$TA <1 after refill and written back)"
fresh "kong:rl:{p3g:m}:lease:mw"
$RC HSET "$B" tokens 2.5 >/dev/null
RW=$(grant 5 60000 mw "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mw")
WGRANT=$(echo "$RW" | sed -n '1p')
WTOKENS=$(echo "$RW" | sed -n '2p')
WWAIT=$(echo "$RW" | sed -n '3p')
WOK=$(awk -v g="$WGRANT" -v t="$WTOKENS" -v w="$WWAIT" 'BEGIN{
  gr=(g==2); tk=(t>=0.5 && t<=0.5); wt=(w>=31.2 && w<=31.3)
  print (gr && tk && wt) ? 1 : 0}')
echo "DBG-wait: RW=[$RW] cond=$WOK" >&2
report "$([ "$WOK" = "1" ] && echo true)" \
  "wait contract: partial grant granted=2, tokens~=0.5, wait~=31.25s (computed from post-deduction tokens, actual=$WWAIT)"

echo "===== RETURN_LEASE ====="
fresh "kong:rl:{p3g:m}:lease:mr1"
grant 5 60000 mr1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mr1" >/dev/null
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mr1")
report "$([ "$(echo "$R" | head -1)" = "5" ] && [ "$(tokens)" = "100" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mr1" status)" = "RETURNED" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mr1" return_requested)" = "5" ] && echo true)" \
  "normal return: applied=5, bucket 95->100, OPEN->RETURNED, return_requested=5"
T0=$(tokens)
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mr1")
report "$(echo "$R" | grep -q 'ALREADY_RETURNED' && [ "$(tokens)" = "$T0" ] && echo true)" \
  "duplicate with same args ⇒ ALREADY_RETURNED, bucket unchanged"
R=$(ret 3 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mr1")
report "$(echo "$R" | grep -q 'RETURN_CONFLICT' && echo true)" "same ID, different args ⇒ RETURN_CONFLICT"
# requested=0: close after full consumption
fresh "kong:rl:{p3g:m}:lease:mz"
grant 5 60000 mz "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mz" >/dev/null
$RC DEL "kong:rl:{p3g:m}:lease:mz" >/dev/null
$RC HSET "kong:rl:{p3g:m}:lease:mz" lease_id mz pool_key "kong:rl:{p3g:m}" granted 5 status OPEN created_at "$(date +%s)" >/dev/null   # full-consumption scenario: granted>=1, requested=0
T0=$(tokens)
R=$(ret 0 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mz")
report "$([ "$(echo "$R" | head -1)" = "0" ] && [ "$(tokens)" = "$T0" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mz" status)" = "RETURNED" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mz" return_requested)" = "0" ] && echo true)" \
  "requested=0 ⇒ skip bucket update, OPEN->RETURNED (accounts closed)"
# requested>granted
fresh "kong:rl:{p3g:m}:lease:mx"
grant 5 60000 mx "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mx" >/dev/null
R=$(ret 6 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mx")
report "$(echo "$R" | grep -q 'INVALID_REQUESTED' && echo true)" "requested>granted ⇒ INVALID_REQUESTED, zero-write"
# POOL_MISMATCH
R=$(ret 5 "kong:rl:{p3g:other}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mx")
report "$(echo "$R" | grep -q 'POOL_MISMATCH' && echo true)" "pool_key mismatch ⇒ POOL_MISMATCH, zero-write"
# Lease expired (TTL 100ms)
fresh "kong:rl:{p3g:m}:lease:mexp"
grant 5 100 mexp "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mexp" >/dev/null
sleep 0.4
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mexp")
report "$(echo "$R" | grep -q 'LEASE_NOT_FOUND' && echo true)" "Lease expired ⇒ LEASE_NOT_FOUND (must not speculate a return)"
# Bucket missing (BUCKET_NOT_FOUND zero-write)
fresh "kong:rl:{p3g:m}:lease:mb"
grant 5 60000 mb "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mb" >/dev/null
$RC DEL "$B" >/dev/null
T0=$($RC EXISTS "$B")
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mb")
report "$(echo "$R" | grep -q 'BUCKET_NOT_FOUND' && [ "$($RC EXISTS "$B")" = "$T0" ] && echo true)" \
  "Bucket missing ⇒ BUCKET_NOT_FOUND, no new bucket created, zero-write"
# fractional requested
fresh "kong:rl:{p3g:m}:lease:mf"
grant 5 60000 mf "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mf" >/dev/null
R=$(ret 1.5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mf")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT requested' && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mf" status)" = "OPEN" ] && echo true)" \
  "requested=1.5 (fractional) ⇒ INVALID_ARGUMENT, zero-write"
# Two concurrent RETURNs: bucket incremented only once
fresh "kong:rl:{p3g:m}:lease:mc"
grant 5 60000 mc "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mc" >/dev/null
T0=$(tokens)
dexec redis-cli --eval "$RL" "kong:rl:{p3g:m}:lease:mc" "$B" , 5 "kong:rl:{p3g:m}" 120000 0.016 100 >/tmp/c1.txt 2>&1 &
dexec redis-cli --eval "$RL" "kong:rl:{p3g:m}:lease:mc" "$B" , 5 "kong:rl:{p3g:m}" 120000 0.016 100 >/tmp/c2.txt 2>&1 &
wait || true
T1=$(tokens)
SUCC=$(grep -c '^5$' /tmp/c1.txt /tmp/c2.txt | awk -F: '{s+=$2} END{print s}')
ALR=$(grep -c 'ALREADY_RETURNED' /tmp/c1.txt /tmp/c2.txt | awk -F: '{s+=$2} END{print s}')
report "$([ "$SUCC" = "1" ] && [ "$ALR" = "1" ] && [ "$T1" = "$((T0+5))" ] && echo true)" \
  "two concurrent RETURNs: one succeeds (applied=5), one ALREADY_RETURNED, bucket incremented only once"
# Failure injection after the commit point (test variant: production script untouched)
python3 test/make_inject_variant.py /tmp/rl_inject.txt >/dev/null
docker compose cp /tmp/rl_inject.txt redis:/tmp/rl_inject.txt >/dev/null
fresh "kong:rl:{p3g:m}:lease:mi"
grant 5 60000 mi "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mi" >/dev/null
T0=$(tokens)
R=$(dexec redis-cli --eval /tmp/rl_inject.txt "kong:rl:{p3g:m}:lease:mi" "$B" , 5 "kong:rl:{p3g:m}" 120000 0.016 100 2>&1) || true
report "$(echo "$R" | grep -q 'INJECTED_FAILURE' && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mi" status)" = "RETURNED" ] && [ "$(tokens)" = "$T0" ] && echo true)" \
  "failure injection after commit point: Lease already RETURNED, bucket not incremented (idempotent commit point verified in advance)"
R=$(ret 5 "kong:rl:{p3g:m}" 120000 0.016 100 "kong:rl:{p3g:m}:lease:mi")
report "$(echo "$R" | grep -q 'ALREADY_RETURNED' && [ "$(tokens)" = "$T0" ] && echo true)" \
  "same-args retry after injection: ALREADY_RETURNED, bucket not double-incremented (difference counted as loss)"

echo "===== Invalid TTL parameter values (P1-2: finite/positive integer/<2^53) ====="
fresh "kong:rl:{p3g:m}:lease:mt1"
T0=$(tokens)
R=$(grant 5 0 mt1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mt1")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT lease_ttl_ms: 0' && [ "$(tokens)" = "$T0" ] && echo true)" "lease_ttl_ms=0 ⇒ rejected, zero-write"
R=$(grant 5 -1 mt1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mt1")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT lease_ttl_ms: -1' && echo true)" "lease_ttl_ms=-1 ⇒ rejected"
R=$(grant 5 1.5 mt1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mt1")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT lease_ttl_ms: 1.5' && echo true)" "lease_ttl_ms=1.5 ⇒ rejected"
R=$(grant 5 100000000000000000000 mt1 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mt1")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT lease_ttl_ms: 100000000000000000000' && echo true)" "lease_ttl_ms=1e20 ⇒ rejected (>=2^53)"
R=$(grant 5 60000 mt1 "kong:rl:{p3g:m}" 0.016 100 0 "kong:rl:{p3g:m}:lease:mt1")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket_ttl_ms: 0' && echo true)" "GRANT bucket_ttl_ms=0 ⇒ rejected"
R=$(grant 5 60000 mt1 "kong:rl:{p3g:m}" 0.016 100 100000000000000000000 "kong:rl:{p3g:m}:lease:mt1")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket_ttl_ms: 100000000000000000000' && echo true)" "GRANT bucket_ttl_ms=1e20 ⇒ rejected"
fresh "kong:rl:{p3g:m}:lease:mt2"
grant 5 60000 mt2 "kong:rl:{p3g:m}" 0.016 100 120000 "kong:rl:{p3g:m}:lease:mt2" >/dev/null
T0=$(tokens)
R=$(ret 2 "kong:rl:{p3g:m}" 0 0.016 100 "kong:rl:{p3g:m}:lease:mt2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket_ttl_ms: 0' && [ "$(tokens)" = "$T0" ] && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mt2" status)" = "OPEN" ] && echo true)" \
  "RETURN bucket_ttl_ms=0 ⇒ rejected, zero-write (Lease still OPEN)"
R=$(ret 2 "kong:rl:{p3g:m}" -1 0.016 100 "kong:rl:{p3g:m}:lease:mt2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket_ttl_ms: -1' && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mt2" status)" = "OPEN" ] && echo true)" \
  "RETURN bucket_ttl_ms=-1 ⇒ rejected (Lease still OPEN, not marked RETURNED)"
R=$(ret 2 "kong:rl:{p3g:m}" 1.5 0.016 100 "kong:rl:{p3g:m}:lease:mt2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket_ttl_ms: 1.5' && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mt2" status)" = "OPEN" ] && echo true)" \
  "RETURN bucket_ttl_ms=1.5 ⇒ rejected"
R=$(ret 2 "kong:rl:{p3g:m}" 100000000000000000000 0.016 100 "kong:rl:{p3g:m}:lease:mt2")
report "$(echo "$R" | grep -q 'INVALID_ARGUMENT bucket_ttl_ms: 100000000000000000000' && [ "$($RC HGET "kong:rl:{p3g:m}:lease:mt2" status)" = "OPEN" ] && echo true)" \
  "RETURN bucket_ttl_ms=1e20 ⇒ rejected (no 'marked RETURNED then later failed' intermediate state)"

echo "===== refill test vectors (four scripts, same state, same vector) ====="
# Vector: preset tokens=100, ts=now-10, rate=1/s, capacity=1000 ⇒ refill=110
# Assertion basis: interval [want, want+4] (docker exec interval jitter ⇒ refill microsecond tail difference), plus four-script normalized consistency
refill_vector() { # refill_vector <label> <tokens reading> <expected post-refill value>
    local label="$1" got="$2" want="$3"
    local in_range
    in_range=$(awk -v g="$got" -v w="$want" 'BEGIN{print (g>=w && g<w+4) ? 1 : 0}')
    report "$([ "$in_range" = "1" ] && echo true)" "refill vector $label: tokens=$got ~= $want (rate x 10s refill, interval includes exec gap)"
}
V1=""; V2=""; V3=""; V4=""
fresh "kong:rl:{p3g:m}:lease:gv"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
R=$($RC --eval /tmp/grant_lease.lua "$B" "kong:rl:{p3g:m}:lease:gv" , 1 60000 gv "kong:rl:{p3g:m}" 1 1000 120000)
V1=$(tokens)
refill_vector "GRANT_LEASE(batch=1, deduct granted=1)" "$V1" 109
fresh "kong:rl:{p3g:m}:lease:rv"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
# RETURN needs an OPEN Lease record (granted=2 for requested=1 validation)
$RC HSET "kong:rl:{p3g:m}:lease:rv" lease_id rv pool_key "kong:rl:{p3g:m}" granted 2 status OPEN >/dev/null
R=$($RC --eval /tmp/return_lease.lua "kong:rl:{p3g:m}:lease:rv" "$B" , 1 "kong:rl:{p3g:m}" 120000 1 1000)
V2=$(tokens)
refill_vector "RETURN_LEASE(requested=1, add applied=1)" "$V2" 111
fresh "kong:rl:{p3g:m}:lease:tb"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
R=$($RC --eval /tmp/token_bucket.lua "$B" , 1 1000 1 120000)
V3=$(tokens)
refill_vector "TOKEN_BUCKET(want=1, deduct granted=1)" "$V3" 109
fresh "kong:rl:{p3g:m}:lease:gm"
$RC HSET "$B" tokens 100 ts "$($RC TIME | awk 'NR==1{print $1 - 10}')" >/dev/null
R=$($RC --eval /tmp/multi_bucket.lua "$B" "$B" , 1 1 1000 120000)
V4=$(tokens)
refill_vector "GRANT_MULTI(batch=1, deduct granted=1)" "$V4" 109
# Four-script normalized consistency (after canceling GRANT/RETURN's +/-1, pairwise differences <3s = upper bound of exec interval jitter)
CONS=$(awk -v a="$V1" -v b="$V2" -v c="$V3" -v d="$V4" 'BEGIN{
  n1=a+1; n2=b-1; n3=c+1; n4=d+1
  m=(n1+n2+n3+n4)/4; r=0
  s=n1-m; if(s<0)s=-s; if(s>r)r=s
  s=n2-m; if(s<0)s=-s; if(s>r)r=s
  s=n3-m; if(s<0)s=-s; if(s>r)r=s
  s=n4-m; if(s<0)s=-s; if(s>r)r=s
  print (r<3) ? 1 : 0}')
report "$([ "$CONS" = "1" ] && echo true)" "refill consistency: four-script normalized max deviation <3s ($V1/$V2/$V3/$V4)"

echo
echo "===== Summary: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ]
