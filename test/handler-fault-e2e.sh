#!/usr/bin/env bash
# ============================================================
# handler-fault-e2e.sh —— 6.2 real-stack verification of fault branches (real fault injection)
#
# Scenario matrix (real Kong + real Redis fault injection, no mocks):
#   Redis healthy with quota             ⇒ 200
#   Redis quota insufficient (batch>1 / batch=1) ⇒ 429 + Retry-After
#   Redis connection refused (docker compose stop redis) ⇒ 503 (ft=false) / degraded (ft=true)
#   Redis timeout (CLIENT PAUSE > timeout) ⇒ 503 (ft=false) / degraded (ft=true)
#   batch=1 / batch>1 faults both 503 (Fail-close semantics does not vary by path)
#   local stock present + Redis fault ⇒ 200 (local TAKE with zero IO — design semantics, see report)
# Log evidence: failing closed / failing open / lease grant failed (uncertain)
# Prerequisites: three nodes restarted with the new handler; independent namespace per run
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
# print the worker_id (the second field of lease_id, host:worker:seq:hex) for all Leases under the given ns
# — the total number of Lease records cannot distinguish "multiple GRANTs by the same Worker"; Worker attribution must use worker_id
lease_worker_ids() {
  RC --scan --pattern 'kong:rl:*:lease:*' </dev/null \
   | while IFS= read -r k; do
       [ -n "$k" ] || continue
       pk=$(RC HGET "$k" pool_key </dev/null)
       case "$pk" in
         *"$1"*) RC HGET "$k" lease_id </dev/null | awk -F: '{print $2}' ;;
       esac
     done
}
PROXY="http://localhost:8030"
RLCONFIG='{"host":"redis","port":6379,"database":0,"timeout":1000}'
RED="\"fault_tolerant\":false,\"redis\":$RLCONFIG"
GRN="\"fault_tolerant\":true,\"redis\":$RLCONFIG"

NS() { echo "$1$$"; }
NS_2D=$(NS h2d); NS_2U=$(NS h2u); NS_1D=$(NS h1d); NS_1U=$(NS h1u)
NS_2R=$(NS h2r); NS_1R=$(NS h1r); NS_2N=$(NS h2n)

# ---- 1. push the 7-route config ----
cat <<EOF > /tmp/opencode/rl62-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"h-2d","paths":["/h2d"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2D",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RED}}]},
  {"name":"h-2u","paths":["/h2u"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2U",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$GRN}}]},
  {"name":"h-1d","paths":["/h1d"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_1D",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$RED}}]},
  {"name":"h-1u","paths":["/h1u"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_1U",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$GRN}}]},
  {"name":"h-2r","paths":["/h2r"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2R",
     "window":3600,"limit":5,"batch":5,"burst":5,"limit_by":["ip"],$RED}}]},
  {"name":"h-1r","paths":["/h1r"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_1R",
     "window":3600,"limit":3,"batch":1,"burst":0,"limit_by":["ip"],$RED}}]},
  {"name":"h-2n","paths":["/h2n"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_2N",
     "window":3600,"limit":100,"batch":50,"burst":0,"limit_by":["ip"],$RED}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl62-config.json >/dev/null \
    || { bad "node :$n config push failed"; exit 1; }
done
ok "config pushed to all three nodes (7 routes: batch>1/batch=1 x ft=false/true x normal/429)"

# ---- 2. Redis healthy: allowed / 429 matrix ----
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h2n")
report "$(eq "$code" 200)" "Redis healthy + quota available ⇒ $code (should be 200)"

# batch>1 429: 6 requests over a single connection (fixed worker) ⇒ 1 GRANT(5) + 4 local TAKEs + the 6th request hits an empty bucket granted=0 ⇒ 429
# (the positional assumption does not hold with multiple workers: each new connection may hit a different worker, so the construction must be deterministic on the same connection)
urls=$(for i in $(seq 1 6); do echo "-o /dev/null $PROXY/h2r"; done)
codes=$(curl -s -w '%{http_code}\n' $urls | tr -d '\r')
seq_codes=$(printf '%s\n' "$codes" | awk '{print $1}' | tr '\n' ' ')
report "$(eq "$seq_codes" "200 200 200 200 200 429 ")" "batch>1 429 sequence=[$seq_codes] (should be 200x5 then 429: 4 local TAKEs + the 6th request granted=0)"
# after the 6 bursts, both workers' GRANTs have empty buckets (granted=0) ⇒ any new-connection request is necessarily 429 ⇒ probe is deterministic
h=$(curl -s -D - -o /dev/null "$PROXY/h2r")
ra=$(sed -n 's/^Retry-After: //pi' <<<"$h" | tr -d '\r')
report "$([ -n "$ra" ] && [ "$ra" -ge 1 ] && echo true)" "429 Retry-After=$ra (existing contract)"
rem6=$(curl -s -D - -o /dev/null "$PROXY/h2r" | sed -n 's/^X-RateLimit-Remaining: //pi' | tr -d '\r')
report "$(eq "$rem6" "0")" "429 X-RateLimit-Remaining=$rem6 (should be 0; at this point both workers' GRANTs have empty buckets ⇒ new requests are necessarily 429)"
body=$(curl -s "$PROXY/h2r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])')
report "$(eq "$body" "API rate limit exceeded")" "429 response body=$body"

# batch=1 429: limit=3 ⇒ the 4th request gets 429
for i in 1 2 3; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h1r")
  [ "$c" = "200" ] || bad "h1r request $i=$c (should be 200)"
done
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h1r")
report "$(eq "$code" 429)" "batch=1 quota insufficient ⇒ $code (should be 429)"

# ---- 2b. fault precondition: make at least two distinct Workers hold local stock ----
# Evidence basis (review fix 1): count the **number of distinct Workers** by the worker_id field of lease_id;
# each Worker's first request performs its own GRANT (Worker isolation). batch=50 ⇒ any Worker's first
# GRANT yields 50 tokens, and <=40 precondition requests are not enough to exhaust any Worker's stock,
# therefore ">=2 distinct worker_ids successfully created a Lease" <=> both Workers hold remaining stock.
TWO_WORKERS=false; wids=""
for i in $(seq 1 40); do
  curl -s -o /dev/null --max-time 5 "$PROXY/h2n" || true
  wids=$(lease_worker_ids "$NS_2N" | sort -u | tr '\n' ',' )
  w=$(lease_worker_ids "$NS_2N" | sort -u | wc -l)
  [ "$w" -ge 2 ] && { TWO_WORKERS=true; break; }
done
if [ "$TWO_WORKERS" = "true" ]; then
  ok "PASS: dual-Worker stock proof: distinct worker_ids=[$wids] (>=2 Workers have each created a Lease ⇒ both hold remaining stock)"
else
  echo "NOT VERIFIED: 40 requests observed no >=2 distinct worker_ids (observed=[${wids:-none}]) — the fault-period 200 counts below do not substitute for this proof"
fi

# ---- 3. fault injection A: Redis connection refused (stop redis) ----
docker compose stop redis >/dev/null 2>&1
sleep 1
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h2d")
report "$(eq "$code" 503)" "connection refused batch>1 ft=false ⇒ $code (should be 503, Fail-close)"
body=$(curl -s "$PROXY/h2d" | python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])')
report "$(eq "$body" "rate limiter unavailable")" "503 response body=$body"
code=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/h1d")
report "$(eq "$code" 503)" "connection refused batch=1 ft=false ⇒ $code (should be 503, Fail-close)"
h=$(curl -s -D - -o /dev/null "$PROXY/h2u")
code=$(head -1 <<<"$h" | awk '{print $2}')
dg=$(sed -n 's/^X-RateLimit-Status: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$code" 200)" "connection refused batch>1 ft=true ⇒ $code (Fail-open should be 200)"
report "$(eq "$dg" "degraded")" "Fail-open marker X-RateLimit-Status=$dg (should be degraded)"
h=$(curl -s -D - -o /dev/null "$PROXY/h1u")
code=$(head -1 <<<"$h" | awk '{print $2}')
dg=$(sed -n 's/^X-RateLimit-Status: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$code" 200)" "connection refused batch=1 ft=true ⇒ $code (Fail-open should be 200)"
report "$(eq "$dg" "degraded")" "Fail-open marker (batch=1)=$dg (should be degraded)"
# Design-semantics observation: h2n already GRANTed in step 2 (some worker holds local remainder) + Redis fault:
#   hitting a worker with stock ⇒ local TAKE allows (200, zero IO); hitting a worker with empty stock ⇒
#   GRANT fails Fail-close (503).
#   The precondition proved both workers hold stock ⇒ during the fault, any worker's request takes the
#   local TAKE path ⇒ all 200 (deterministic)
obs_codes=$(for i in 1 2 3 4 5 6; do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 "$PROXY/h2n" &
done; wait)
obs_dist=$(printf '%s\n' "$obs_codes" | sort | uniq -c | sort -rn | tr '\n' ';')
if [ "$TWO_WORKERS" = "true" ]; then
  report "$(eq "$(printf '%s\n' "$obs_codes" | grep -c 200)" 6)" "observation: local stock + Redis fault ⇒ all 6 requests 200 (distribution=[$obs_dist]; local TAKE with zero IO, no fault branch touched — design semantics)"
else
  report "$(! grep -q 429 <<<"$obs_codes" && echo true)" "observation (degraded): no 429 during the Redis fault (distribution=[$obs_dist]; 200=stock allows / 503=empty-stock Fail-close)"
  echo "NOT VERIFIED: local TAKE fault-period allowance evidence (dual-Worker stock precondition unproven, observation item degraded to the core invariant)"
fi

# ---- 4. fault injection B: Redis timeout (CLIENT PAUSE 6s > timeout 1s, 4 requests fired in parallel)----
# PAUSE is a global time window: sequential requests would eat the window between them ⇒ firing in
# parallel guarantees every request times out inside the window
docker compose start redis >/dev/null 2>&1
for t in $(seq 1 20); do RC PING >/dev/null 2>&1 && break; sleep 1; done
RC CLIENT PAUSE 6000 >/dev/null
curl -s -o /dev/null -w 'h2d=%{http_code}\n' --max-time 8 "$PROXY/h2d"  > /tmp/opencode/rl62-t1 &
curl -s -o /dev/null -w 'h1d=%{http_code}\n' --max-time 8 "$PROXY/h1d"  > /tmp/opencode/rl62-t2 &
curl -s -D /tmp/opencode/rl62-t3.h -o /dev/null -w 'h2u=%{http_code}\n' --max-time 8 "$PROXY/h2u" > /tmp/opencode/rl62-t3 &
curl -s -D /tmp/opencode/rl62-t4.h -o /dev/null -w 'h1u=%{http_code}\n' --max-time 8 "$PROXY/h1u" > /tmp/opencode/rl62-t4 &
wait
code=$(sed -n 's/^h2d=//p' /tmp/opencode/rl62-t1)
report "$(eq "$code" 503)" "Redis timeout (CLIENT PAUSE) batch>1 ft=false ⇒ $code (should be 503; uncertain outcome, no retry, no registration)"
code=$(sed -n 's/^h1d=//p' /tmp/opencode/rl62-t2)
report "$(eq "$code" 503)" "Redis timeout batch=1 ft=false ⇒ $code (should be 503)"
code=$(sed -n 's/^h2u=//p' /tmp/opencode/rl62-t3)
dg=$(sed -n 's/^X-RateLimit-Status: //pi' /tmp/opencode/rl62-t3.h | tr -d '\r')
report "$(eq "$code" 200)" "Redis timeout batch>1 ft=true ⇒ $code (Fail-open)"
report "$(eq "$dg" "degraded")" "timeout Fail-open marker=$dg"
code=$(sed -n 's/^h1u=//p' /tmp/opencode/rl62-t4)
dg=$(sed -n 's/^X-RateLimit-Status: //pi' /tmp/opencode/rl62-t4.h | tr -d '\r')
report "$(eq "$code" 200)" "Redis timeout batch=1 ft=true ⇒ $code (Fail-open)"
report "$(eq "$dg" "degraded")" "timeout Fail-open marker (batch=1)=$dg"
# Semantics note (review fix 2): after a GRANT timeout, Redis may already have executed (bucket debited
# + Lease record created); the presence or absence of Redis metadata **cannot** prove whether registration
# happened locally; the uncertain-outcome "no retry / no registration in the local lease pool / no 429
# conversion" is guaranteed by Phase 4 unit tests and code paths (test/lease-unit.sh uncertain case).
# This group's real-stack verification point = post-timeout HTTP 503 / Fail-open semantics
# (see assertions above and §5 log evidence).
sleep 4

# ---- 5. log evidence ----
logs=""
for r in 1 2 3; do
  logs=$(docker compose logs kong1 --since 10m 2>&1 || true)
  [ "${#logs}" -gt 1000 ] && break
  sleep 2
done
# Note: under pipefail, grep -q (exits on first match) makes the upstream echo receive SIGPIPE ⇒
# short-circuit becomes unreliable; use grep -c (reads all input) for counting checks consistently
report "$([ "$(echo "$logs" | grep -c "limiter unavailable, failing closed")" -ge 1 ] && echo true)" "logs contain failing closed (Fail-close evidence)"
report "$([ "$(echo "$logs" | grep -c "limiter unavailable, failing open")" -ge 1 ] && echo true)" "logs contain failing open (Fail-open evidence)"
report "$([ "$(echo "$logs" | grep -c "lease grant failed (uncertain)")" -ge 1 ] && echo true)" "logs contain lease grant failed (uncertain) (timeout classification evidence)"
n429=$(echo "$logs" | grep -c "rate-limit-advanced: 429 " || true)
report "$([ "$n429" -ge 2 ] && echo true)" "logs contain 429 decision notices x$n429 (deterministic denial distinguishable from fault logs)"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
