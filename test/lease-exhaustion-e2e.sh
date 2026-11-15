#!/usr/bin/env bash
# ============================================================
# lease-exhaustion-e2e.sh —— 6.5 test 2: stock exhaustion and re-request (single connection pins a Worker)
#
# Scenario (batch=10, a single keepalive connection ⇒ the same Worker consumes sequentially):
#   req1   ⇒ GRANT Lease A (granted=10), consumes 1 ⇒ remaining=9
#   req2-10 ⇒ local TAKE ⇒ remaining 8..0 (after req10 Lease A is exhausted ⇒ removed locally as CLOSED)
#   req11  ⇒ new GRANT Lease B (new lease_id, granted=10) consumes 1 ⇒ remaining=9
#   req12  ⇒ remaining=8
# Assertions: A != B; A's stock is not double-consumed; B does not reuse A's stock (rem=9 not >=10);
#       CLOSED leases no longer participate in TAKE (req11 triggers a new GRANT rather than old stock);
#       multi-Lease coexistence management without degradation; different Workers' local stock is
#       independent (the second connection's first request has remaining=9 ⇒ an independent Pool, not a shared 8)
# Observation basis: X-RateLimit-Remaining = local pool remainder (algorithm.lua:423-424)
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
NS="p65e$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

RC PING >/dev/null || { bad "Redis unavailable"; exit 1; }
cat <<EOF > /tmp/opencode/p65e-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"exh","paths":["/exh"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
   "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65e-config.json >/dev/null \
    || { bad "node :$n config push failed"; exit 1; }
done
ok "config pushed: limit=100 window=86400 batch=10 ns=$NS"

# ---- keepalive HTTP helper (/dev/tcp; reads the full response including body, keeping the connection for reuse) ----
http_req() { # $1=fd $2=path ⇒ prints "status remaining"
  printf 'GET /%s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n' "$2" >&"$1" || { echo "ERR send"; return; }
  local line status="" rem="" cl=0
  read -r -t 8 line <&"$1" || { echo "ERR read"; return; }
  status=$(printf '%s' "$line" | awk '{print $2}')
  while IFS= read -r -t 8 line <&"$1"; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
    case "$line" in
      Content-Length:*) cl=${line#*: } ;;
      X-RateLimit-Remaining:*) rem=${line#*: } ;;
    esac
  done
  if [ "${cl:-0}" -gt 0 ] 2>/dev/null; then
    IFS= read -r -N "$cl" -t 8 body <&"$1" || true
  fi
  echo "$status ${rem:-NA}"
}

exec 3<>/dev/tcp/127.0.0.1/8030 || { bad "cannot establish the keepalive connection"; exit 1; }
ok "keepalive connection established (fd3, pins a single Worker)"

# ---- 12 sequential requests ----
declare -a STATUS REM
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  out=$(http_req 3 exh)
  STATUS[$i]=${out%% *}
  REM[$i]=${out#* }
  echo "req$i: status=${STATUS[$i]} remaining=${REM[$i]}"
done
exec 3>&- 3<&-

# ---- assertions: status codes and the remaining sequence ----
seqok=true
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ "${STATUS[$i]}" = "200" ] || seqok=false
done
report "$seqok" "all 12 requests 200 (the exhaustion switchover produces no error responses)"
expected="9 8 7 6 5 4 3 2 1 0 9 8"
actual="${REM[1]} ${REM[2]} ${REM[3]} ${REM[4]} ${REM[5]} ${REM[6]} ${REM[7]} ${REM[8]} ${REM[9]} ${REM[10]} ${REM[11]} ${REM[12]}"
report "$(eq "$actual" "$expected")" "remaining sequence=$actual (expected $expected: Pool A 10->0 exhausted; req11 gets a new GRANT into Pool B, 9)"

# ---- Lease record verification (ascending created_at: A=created first, B=new GRANT after exhaustion) ----
recs=$(RC --scan --pattern 'kong:rl:*:lease:*' </dev/null | while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) echo "$k";; esac
done)
nrec=$(echo "$recs" | grep -c . || true)
report "$(eq "$nrec" 2)" "lease record count=$nrec (exactly 2: Lease A + Lease B; req11 triggered a new GRANT with no silent allowance from old stock)"
KA=$(echo "$recs" | head -1); KB=$(echo "$recs" | tail -1)
cKA=$(RC HGET "$KA" created_at </dev/null | tr -d '\r'); cKB=$(RC HGET "$KB" created_at </dev/null | tr -d '\r')
if awk -v a="$cKA" -v b="$cKB" 'BEGIN{exit !(b<a)}'; then KA=$(echo "$recs" | tail -1); KB=$(echo "$recs" | head -1); fi
lidA=$(RC HGET "$KA" lease_id </dev/null | tr -d '\r')
lidB=$(RC HGET "$KB" lease_id </dev/null | tr -d '\r')
gA=$(RC HGET "$KA" granted </dev/null | tr -d '\r')
gB=$(RC HGET "$KB" granted </dev/null | tr -d '\r')
cA=$(RC HGET "$KA" created_at </dev/null | tr -d '\r')
cB=$(RC HGET "$KB" created_at </dev/null | tr -d '\r')
sA=$(RC HGET "$KA" status </dev/null | tr -d '\r')
sB=$(RC HGET "$KB" status </dev/null | tr -d '\r')
report "$([ "$lidA" != "$lidB" ] && echo true || echo false)" "Lease A != Lease B (seq: $(echo "$lidA" | cut -d: -f3) vs $(echo "$lidB" | cut -d: -f3))"
report "$(eq "$gA$gB" "1010")" "both records have granted=10 (A:$gA B:$gB)"
report "$(awk -v a="$cA" -v b="$cB" 'BEGIN{print (b>=a)?"true":"false"}')" "Lease B created_at >= A (B is the new GRANT after exhaustion)"
report "$(eq "$sA$sB" "OPENOPEN")" "both records have status=OPEN (V1: CLOSED is local semantics; the Redis side stays OPEN until TTL — frozen basis)"

# ---- independence of different Workers' local stock ----
# the pool of the Worker owning fd3 (Pool B) currently has outstanding=8. A new connection hitting a
# different Worker ⇒ an independent Pool ⇒ a new GRANT ⇒ the record count +1 (and the first request's
# remaining=9);
# hitting the same Worker ⇒ the shared Pool B ⇒ remaining decreases (7,6,...) and the record count is unchanged.
# Each probe uses a new connection (random Worker), up to 8 times; the record count increase is the
# independence criterion.
indep=false
for t in 1 2 3 4 5 6 7 8; do
  exec 4<>/dev/tcp/127.0.0.1/8030
  out=$(http_req 4 exh)
  exec 4>&- 4<&-
  st=${out%% *}; rm2=${out#* }
  nrec_now=$(RC --scan --pattern 'kong:rl:*:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$NS"*) echo x;; esac
  done | wc -l | tr -d ' ')
  echo "independence probe #$t: status=$st remaining=$rm2 record count=$nrec_now"
  [ "$st" = "200" ] || continue
  if [ "$nrec_now" -gt "$nrec" ]; then
    indep=true; break
  fi
done
report "$indep" "a new connection triggered an independent new Pool (the record count increases ⇒ different Workers' local stock is independent, not shared Pool B)"
nrec3=$nrec_now
report "$([ "$nrec3" -ge 3 ] && echo true)" "multi-Lease coexistence: record count=$nrec3 >=3 (A/B + the independent Worker's new Lease; coexistence management without degradation)"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
