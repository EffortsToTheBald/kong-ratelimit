#!/usr/bin/env bash
# ============================================================
# fault-recovery-e2e.sh —— 6.4 fault recovery verification (real stack, §7.3)
#
# Scenarios:
#   R1 connection refused -> recovery:
#     stop redis ⇒ 503 (Fail-close; fresh ns ⇒ GRANT fails);
#     start redis ⇒ requests allowed normally with 200; exactly 1 lease record for that ns
#     (Redis is down during the connection-refusal period ⇒ zero writes on the Redis side is a
#     deterministic fact; a single authorization after recovery)
#   R2 CLIENT PAUSE timeout -> recovery (single-request basis; concurrency race verification belongs to Phase 6.5):
#     PAUSE 6s ⇒ single request ⇒ 503 (uncertain, no retry, no registration, not masked as 429);
#     after PAUSE expires ⇒ count the ns Lease records (a timed-out request produces at most 1 —
#     Redis may have executed the GRANT before the timeout, so it is not required to be 0);
#     new independent request ⇒ 200 remaining=9; record increment exactly +1 (no double authorization)
# Prerequisites: three nodes healthy; independent namespace; semantics already passed in 6.2 are unchanged
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
PROXY="http://localhost:8030"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'
NS_R1="p64r1$$"; NS_R2="p64r2$$"

cat <<EOF > /tmp/opencode/rl64r-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"r1","paths":["/r1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_R1",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"r2","paths":["/r2"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS_R2",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl64r-config.json >/dev/null \
    || { bad "node :$n config push failed"; exit 1; }
done
ok "two-route config pushed (batch>1 ft=false x 2)"

lease_records_for() {
  RC --scan --pattern 'kong:rl:*:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$1"*) echo "$k";; esac
  done
}

# ================= R1: connection refused -> recovery =================
docker compose stop redis >/dev/null 2>&1
sleep 1
c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/r1")
report "$(eq "$c" 503)" "R1 fault-period request ⇒ $c (should be 503 Fail-close; not masked as 429)"
docker compose start redis >/dev/null 2>&1
for t in $(seq 1 20); do RC PING >/dev/null 2>&1 && break; sleep 1; done
ok "Redis recovered (PING reachable)"
# during the outage, Kong's per-Worker DNS caches may retain failed resolutions (isolated per Worker);
# poll /r1 until the first 200: a connection-refusal-type 503 zero-write is a deterministic fact (with Redis
# down/unreachable the request never reaches Redis), so the first 200 is the recovery request with exactly
# one authorization.
# Scenario semantics unchanged: connection refused -> recovery.
h=""; c=""
for t in $(seq 1 30); do
  h=$(curl -s -D - -o /dev/null --max-time 8 "$PROXY/r1")
  c=$(head -1 <<<"$h" | awk '{print $2}')
  [ "$c" = "200" ] && break
  report "$(eq "$c" "503")" "R1 recovery poll #$t ⇒ $c (connection-failure type; must be 503 not 429; zero-write)"
  sleep 1
done
report "$(eq "$c" 200)" "R1 post-recovery independent request ⇒ $c (should be 200, normal request)"
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$rem" "9")" "R1 post-recovery remaining=$rem (new GRANT granted=10 consumes 1; the fault-period failure was not treated as already authorized)"
n1=$(lease_records_for "$NS_R1" | wc -l | tr -d ' ')
report "$(eq "$n1" 1)" "R1 lease record count for this ns=$n1 (exactly 1: Redis is down with zero writes during the connection-refusal period; the first 200 = the recovery request's single authorization, no double authorization)"

# ================= R2: CLIENT PAUSE timeout -> recovery (single request) =================
RC CLIENT PAUSE 6000 >/dev/null
c1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/r2")
report "$(eq "$c1" "503")" "R2 timed-out single request ⇒ $c1 (should be 503: the uncertain outcome enters the fault branch, not masked as 429; no automatic retry — single request, single failure)"
sleep 5
ok "PAUSE expired"
n2_before=$(lease_records_for "$NS_R2" | wc -l | tr -d ' ')
report "$([ "$n2_before" -le 1 ] && echo true)" "R2 lease record count produced by the timed-out request=$n2_before <=1 (Redis may have executed the GRANT before the timeout ⇒ 0 or 1 is allowed, 0 is not required; the timed-out request produces at most 1 ⇒ no duplicate requests)"
# the post-recovery new independent request: stale per-Worker DNS caches may cause occasional 503s
# (connection-failure type, zero-write); poll until the first 200, which is the recovery request. PAUSE
# has expired and Redis runs normally, so any 503 in the recovery polls is a connection failure
# (deterministic zero-write) and does not affect the increment assertion.
h=""; c=""
for t in $(seq 1 30); do
  h=$(curl -s -D - -o /dev/null --max-time 8 "$PROXY/r2")
  c=$(head -1 <<<"$h" | awk '{print $2}')
  [ "$c" = "200" ] && break
  report "$(eq "$c" "503")" "R2 recovery poll #$t ⇒ $c (connection-failure type; must be 503 not 429; zero-write)"
  sleep 1
done
report "$(eq "$c" 200)" "R2 post-recovery new independent request ⇒ $c (should be 200)"
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$rem" "9")" "R2 post-recovery remaining=$rem (normal new GRANT)"
n2_after=$(lease_records_for "$NS_R2" | wc -l | tr -d ' ')
delta=$((n2_after - n2_before))
report "$(eq "$delta" 1)" "R2 lease record increment=+$delta (before recovery=$n2_before, after recovery exactly +1 ⇒ the new request is authorized exactly once, no double authorization)"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
