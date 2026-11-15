#!/usr/bin/env bash
# ============================================================
# algorithm-lease-e2e.sh —— 6.1 real-stack E2E smoke: three-mode path split
#
# Coverage (E2E layer of user acceptance test §5 items 1/2/3/4/5/7/11, real Kong + real Redis):
#   batch>1: first request GRANT_LEASE (Redis lease record OPEN) + the current request consumes
#            exactly 1 (X-RateLimit-Remaining = granted-1); subsequent requests take locally with
#            zero new GRANTs; local exhaustion ⇒ re-request (a second lease record; the old record
#            is not overwritten — coexistence)
#   batch=1: produces no lease record at all (a TOKEN_BUCKET record exists)
#   multi rules: GRANT_MULTI debits two buckets, zero lease records
# Run: bash+curl; prerequisite: the three nodes have been restarted with the new code (docker compose restart)
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

# An independent namespace per run (with timestamp) ⇒ new policy fingerprint ⇒ local lease pool and
# Redis records fully isolated
# (Redis FLUSHDB cannot clear Worker-local Lease stock — V1 frozen semantics, so the fingerprint must change)
NS_G1="rl6g1$$"; NS_B1="rl6b1$$"; NS_M="rl6m$$"

# ---- 1. push the three-route config (DB-less full replacement, identical config on all three nodes) ----
mkdir -p /tmp/opencode
cat <<EOF > /tmp/opencode/rl6-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"echo-route","paths":["/echo"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"${NS_G1}",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]},
  {"name":"echo-b1","paths":["/b1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"${NS_B1}",
     "window":3600,"limit":50,"batch":1,"burst":0,"limit_by":["ip"],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]},
  {"name":"echo-multi","paths":["/multi"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"${NS_M}",
     "limit":50,"window":3600,"burst":0,"fault_tolerant":false,
     "redis":{"host":"redis","port":6379,"database":0,"timeout":1000},
     "rules":[{"limit":100,"window":3600,"limit_by":["ip"]},
              {"limit":50,"window":3600,"limit_by":["ip"]}]}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl6-config.json >/dev/null \
    || { bad "node :$n config push failed"; exit 1; }
done
ok "config pushed to all three nodes (batch=10 / batch=1 / multi rules)"

# ---- 2. flush Redis to guarantee observation from zero ----
RC FLUSHDB >/dev/null

# lease records belong to a namespace via the pool_key field (the lease key itself has no namespace)
lease_ns_count() {
  RC --scan --pattern 'kong:rl:*:lease:*' \
   | while IFS= read -r k; do [ -n "$k" ] && RC HGET "$k" pool_key </dev/null; done \
   | grep -c "$1" || true
}
lease_status() { RC HGET "$1" status; }

# ---- 3. batch>1: 10 requests over one connection (1 GRANT + 9 local TAKEs, deterministic same worker)----
urls=$(for i in $(seq 1 10); do echo "-o /dev/null $PROXY/echo"; done)
out=$(curl -s -D /tmp/opencode/rl6-h1.txt -w '%{http_code}\n' $urls)
rem1=$(sed -n 's/^x-ratelimit-remaining: //pi' /tmp/opencode/rl6-h1.txt | tr -d '\r')
code=$(head -1 <<<"$out")
# the remaining values of the 10 responses are appended in one file: 9,8,...,0 ⇒ each request consumes exactly 1, the 10th exhausts
rem_trace=$(echo "$rem1" | tr '\n' ' ')
expect="9 8 7 6 5 4 3 2 1 0 "
report "$(eq "$code" 200)" "first request HTTP status=$code (should be 200)"
report "$(eq "$rem_trace" "$expect")" "remaining sequence=[$rem_trace] (should=$expect: each request consumes exactly 1, the current request is neither missed nor double-consumed after GRANT)"
n1=$(lease_ns_count "$NS_G1")
report "$(eq "$n1" 1)" "lease record count after 10 requests=$n1 (should be 1: 1 GRANT + 9 local TAKEs, zero new GRANTs on the same worker)"
# take only this run's namespace lease records (attributed by pool_key, guarding against residue interference)
lkey=$(RC --scan --pattern 'kong:rl:*:lease:*' | while IFS= read -r k; do
    [ -n "$k" ] && RC HGET "$k" pool_key </dev/null | grep -q "$NS_G1" && echo "$k"
  done | head -1)
[ -n "$lkey" ] || { bad "lease record for $NS_G1 not found"; exit 1; }
report "$(eq "$(lease_status "$lkey")" OPEN)" "lease record status=$(lease_status "$lkey") (should be OPEN)"
pk=$(RC HGET "$lkey" pool_key)
bkt=$(RC --scan --pattern "kong:rl:*${NS_G1}*" | grep -v lease | head -1)
report "$(eq "$pk" "$bkt")" "pool_key == bucket key (D7: pool_key=existing bucket key) | $pk vs $bkt"

# ---- 5. another 11 requests (new connection ⇒ possibly another worker): local exhaustion ⇒ re-request ----
# 21 requests consume 21 tokens, at most 10 per Lease ⇒ at least 3 GRANT records globally (no cross-worker sharing)
urls=$(for i in $(seq 11 21); do echo "-o /dev/null $PROXY/echo"; done)
codes=$(curl -s -w '%{http_code}\n' $urls)
report "$(eq "$(printf '%s\n' "$codes" | grep -vc 200)" 0)" "requests 11-21 all 200"
n2=$(lease_ns_count "$NS_G1")
report "$([ "$n2" -ge 3 ] && echo true)" "lease record count after 21 requests=$n2 (should be >=3: at most 10 per Lease and no cross-worker takeover)"
report "$(eq "$(lease_status "$lkey")" OPEN)" "first lease record still present with status=$(lease_status "$lkey") (coexistence without overwrite; V1 has no RETURN ⇒ OPEN on the Redis side — CLOSED is local semantics)"

# ---- 6. batch=1: zero lease records ----
for i in 1 2 3; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/b1")
  [ "$c" = "200" ] || bad "batch=1 request $i status=$c"
done
report "$(eq "$(lease_ns_count "$NS_B1")" 0)" "batch=1 lease record count=$(lease_ns_count "$NS_B1") (should be 0)"
b1_bucket=$(RC --scan --pattern "kong:rl:*${NS_B1}*" | grep -vc lease || true)
report "$(eq "$b1_bucket" 1)" "batch=1 bucket record count=$b1_bucket (TOKEN_BUCKET debits normally)"

# ---- 7. multi rules: GRANT_MULTI double bucket, zero lease ----
h=$(curl -s -D - -o /dev/null "$PROXY/multi")
code=$(head -1 <<<"$h" | awk '{print $2}')
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$code" 200)" "multi-rule request status=$code"
report "$(eq "$rem" "49")" "multi-rule X-RateLimit-Remaining=$rem (bottleneck rule limit=50 consumes 1 ⇒ 49)"
report "$(eq "$(lease_ns_count "$NS_M")" 0)" "multi-rule lease record count=$(lease_ns_count "$NS_M") (should be 0)"
m_bucket=$(RC --scan --pattern "kong:rl:*${NS_M}*" | grep -vc lease || true)
report "$(eq "$m_bucket" 2)" "multi-rule bucket record count=$m_bucket (GRANT_MULTI debits two buckets atomically)"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
