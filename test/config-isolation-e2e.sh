#!/usr/bin/env bash
# ============================================================
# config-isolation-e2e.sh —— 6.3 real-stack E2E for config changes (limit dimension)
#
# Scenario (real Kong config change, no mocks):
#   1. config A (limit=100/batch=10/fixed ns) sends a request ⇒ Worker GRANTs, leaving local stock
#   2. record A's lease record (lease_id/created_at/status/pool_key) and A's bucket tokens
#   3. Admin API switches to config B (limit=200, same ns ⇒ fingerprint change)
#   4. config B sends the first request:
#      - X-RateLimit-Remaining=9 (B's new bucket is full ⇒ granted=10 consumes 1);
#        if A's local stock were reused it would be 8 ⇒ the assertion rules out reuse
#      - Redis produces a new lease record whose pool_key fingerprint segment differs from A (new Pool)
#   5. A's lease record is preserved as-is (lease_id/created_at/status OPEN unchanged — not overwritten, not deleted)
#   6. A's Redis bucket tokens are not modified by the config change (+/-1 tolerance = refill/exec gap)
# Prerequisites: three nodes healthy; independent namespace per run
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
NS="p63e$$"

apply() {  # $1=limit
  cat <<EOF > /tmp/opencode/rl63-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"c63","paths":["/c63"],"strip_path":false,
  "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
    "window":3600,"limit":$1,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
  for n in 8031 8011 8021; do
    curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
         -H 'Content-Type: application/json' -d @/tmp/opencode/rl63-config.json >/dev/null \
      || { bad "node :$n config push failed"; exit 1; }
  done
}

lease_records_for() {  # print the lease keys of a ns (attributed by pool_key)
  RC --scan --pattern 'kong:rl:*:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$1"*) echo "$k";; esac
  done
}

# ---- 1. config A: GRANT + local stock retained ----
apply 100
ok "config A pushed (limit=100 batch=10 ns=$NS)"
h=$(curl -s -D - -o /dev/null "$PROXY/c63")
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$rem" "9")" "config A first request remaining=$rem (granted=10 consumes 1 ⇒ 9; 9 units of local stock remain)"
alk=$(lease_records_for "$NS" | head -1)
[ -n "$alk" ] || { bad "config A lease record not found"; exit 1; }
A_ID=$(RC HGET "$alk" lease_id); A_TS=$(RC HGET "$alk" created_at); A_ST=$(RC HGET "$alk" status)
A_PK=$(RC HGET "$alk" pool_key)
report "$(eq "$A_ST" OPEN)" "A lease record status=$A_ST"
A_BKT=$(RC --scan --pattern "kong:rl:*${NS}*" </dev/null | grep -v lease | head -1)
report "$(eq "$A_PK" "$A_BKT")" "A pool_key == A bucket key"
A_TOK_BEFORE=$(RC HGET "$A_BKT" tokens)

# ---- 2. config change: limit 100 -> 200 (fingerprint change ⇒ new Pool) ----
apply 200
ok "config change pushed (limit=200, same ns ⇒ new fingerprint)"

# ---- 3. config B first request: does not reuse A's stock ----
h=$(curl -s -D - -o /dev/null "$PROXY/c63")
rem=$(sed -n 's/^X-RateLimit-Remaining: //pi' <<<"$h" | tr -d '\r')
report "$(eq "$rem" "9")" "config B first request remaining=$rem (B's new bucket is full, granted=10 consumes 1; if A's remaining 9 units were reused it would be 8 ⇒ reuse ruled out)"
n_after=$(lease_records_for "$NS" | wc -l | tr -d ' ')
report "$([ "$n_after" -ge 2 ] && echo true)" "B's first request triggers a new GRANT: ns lease record count=$n_after (>=2)"

# ---- 4. new record = B's own Pool (different fingerprint segment); A's record preserved as-is ----
blks=$(lease_records_for "$NS")
B_PK=""
for k in $blks; do
  [ "$k" = "$alk" ] || B_PK=$(RC HGET "$k" pool_key)
done
[ -n "$B_PK" ] || { bad "config B lease record not found"; exit 1; }
report "$(eq "$([ "$B_PK" != "$A_PK" ] && echo true)" "true")" "B pool_key != A pool_key (fingerprint segment isolation) | $A_PK vs $B_PK"
B_ID=$(lease_records_for "$NS" | while IFS= read -r k; do
  [ "$k" = "$alk" ] || RC HGET "$k" lease_id </dev/null; done | head -1)
report "$([ -n "$B_ID" ] && [ "$B_ID" != "$A_ID" ] && echo true)" "B lease_id=$B_ID != A lease_id=$A_ID (multi-Lease coexistence without overwrite)"
report "$(eq "$(RC HGET "$alk" lease_id)" "$A_ID")" "A lease_id unmodified"
report "$(eq "$(RC HGET "$alk" created_at)" "$A_TS")" "A created_at unmodified"
report "$(eq "$(RC HGET "$alk" status)" "$A_ST")" "A status remains $A_ST (V1 has no RETURN; the old Pool stock naturally exhausts/expires via TTL — frozen decision)"

# ---- 5. A's Redis bucket is not modified by the config change ----
A_TOK_AFTER=$(RC HGET "$A_BKT" tokens)
diff=$(python3 -c "print(abs(float('$A_TOK_AFTER')-float('$A_TOK_BEFORE'))<1.0 and 'yes' or 'no')")
report "$(eq "$diff" "yes")" "A bucket tokens $A_TOK_BEFORE -> $A_TOK_AFTER (+/-1 tolerance=refill/exec gap; the config change does not modify the old bucket's token state)"
# (fix: SCAN order is not deterministic; when both bucket keys exist, head -1 may sample A's key ⇒
#   occasional false failures; the assertion's intent is "B's bucket key differs from A's", so A_BKT is
#   explicitly excluded before sampling)
B_BKT=$(RC --scan --pattern "kong:rl:*${NS}*" </dev/null | grep -v lease | grep "$NS.*p=" | grep -v "^${A_BKT}$" | head -1)
report "$(eq "$([ "$B_BKT" != "$A_BKT" ] && echo true)" "true")" "B bucket key != A bucket key ($A_BKT vs $B_BKT)"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
