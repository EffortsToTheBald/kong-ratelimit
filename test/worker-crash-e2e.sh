#!/usr/bin/env bash
# ============================================================
# worker-crash-e2e.sh -- 6.5 Test 3: Worker kill -9 and lease loss (focus of this phase)
#
# Scenario (batch=10, limit=100, window=86400 => refill<0.1 token throughout):
#   1. A keepalive connection pins Worker W of kong1 (/proc/net/tcp inode -> PID proof)
#   2. 4 requests on W => GRANT L1 (granted=10), consume 4 => outstanding=6
#      (proven by X-RateLimit-Remaining sequence 9,8,7,6)
#   3. kill -9 W (PID proven exited)
#   4. Continue sending 150 requests to the remaining Workers => each gets a new GRANT
# Ledger acceptance:
#   Before W crash: granted(10) = consumed(4) + outstanding(6)
#   After W crash: granted(10) = consumed(4) + lost(6)
#   No takeover: global allowed = 4 + 90 = 94 != 100 (the 6 lost tokens never revive)
#   No RETURN/compensation: L1 record fields untouched (OPEN/granted=10/created_at unchanged)
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
NS="p65k$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

RC PING >/dev/null || { bad "Redis unavailable"; exit 1; }
cat <<EOF > /tmp/opencode/p65k-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"crash","paths":["/crash"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
   "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65k-config.json >/dev/null \
    || { bad "config push failed on node :$n"; exit 1; }
done
ok "config pushed: limit=100 window=86400 batch=10 ns=$NS"

http_req() { # $1=fd $2=path => "status remaining"
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

# ---- 1. Pin the connection + PID mapping (before requests, the idle connection was already accepted by some Worker) ----
exec 3<>/dev/tcp/127.0.0.1/8030 || { bad "unable to establish keepalive connection"; exit 1; }
sleep 0.5
inode=$(docker exec kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | head -1 | awk '{print $10}')
report "$([ -n "$inode" ] && echo true)" "connection established, inode=$inode (proven via /proc/net/tcp)"
wpid=""
for pid in $(docker exec kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
  if docker exec kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inode\]'" </dev/null; then
    if [ -z "$wpid" ]; then wpid=$pid; else dup=true; fi
  fi
done
report "$([ -n "$wpid" ] && [ -z "${dup:-}" ] && echo true)" "connection owned by Worker PID=$wpid uniquely (inode->fd proof; kill target determined)"

# ---- 2. Consume 4 on W (granted=10 => consumed=4, outstanding=6) ----
declare -a REM
for i in 1 2 3 4; do
  out=$(http_req 3 crash)
  st=${out%% *}; REM[$i]=${out#* }
  report "$(eq "$st" 200)" "pre-crash req$i on W => $st remaining=${REM[$i]}"
done
exec 3>&- 3<&-
report "$(eq "${REM[1]} ${REM[2]} ${REM[3]} ${REM[4]}" "9 8 7 6")" "outstanding evolution 9->8->7->6 (granted=10, consumed=4, outstanding=6)"
L1=$(RC --scan --pattern 'kong:rl:*:lease:*' </dev/null | while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) echo "$k"; break;; esac
done | head -1)
g1=$(RC HGET "$L1" granted </dev/null | tr -d '\r')
s1=$(RC HGET "$L1" status </dev/null | tr -d '\r')
c1=$(RC HGET "$L1" created_at </dev/null | tr -d '\r')
lid1=$(RC HGET "$L1" lease_id </dev/null | tr -d '\r')
report "$(eq "$g1$s1" "10OPEN")" "W's lease L1: granted=$g1 status=$s1 (lease_id=$lid1, worker segment=$(echo "$lid1" | cut -d: -f2))"

# ---- 3. kill -9 the target Worker ----
docker exec kong1 kill -9 "$wpid"
alive=true
for t in $(seq 1 20); do
  docker exec kong1 sh -c "ps -o pid= -p $wpid" </dev/null >/dev/null 2>&1 || { alive=false; break; }
  sleep 0.5
done
report "$(eq "$alive" false)" "Worker PID=$wpid exited (kill -9 target confirmed; polled ps every 0.5s for 10s)"

# ---- 4. Continue requests on the remaining Workers (150, new connections) ----
: > /tmp/opencode/p65k-post.txt
for i in $(seq 1 150); do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 "$PROXY/crash" >> /tmp/opencode/p65k-post.txt
done
p200=$(grep -c '^200$' /tmp/opencode/p65k-post.txt || true)
p429=$(grep -c '^429$' /tmp/opencode/p65k-post.txt || true)
pother=$(grep -cv '^200$\|^429$' /tmp/opencode/p65k-post.txt || true)
report "$(eq "$pother" 0)" "no 5xx/abnormal status codes after crash (other=$pother)"
report "$(eq "$p200" 90)" "allowed after crash=$p200 (exactly 90: 9x batch=10 all consumed; W's 6 lost tokens are never re-granted)"
report "$(eq "$p429" 60)" "429 after crash=$p429 (existing semantics of denied-GRANT once the bucket is drained)"

# ---- Ledger verification ----
records=0; sum_granted=0
while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) records=$((records+1)); g=$(RC HGET "$k" granted </dev/null | tr -d '\r'); sum_granted=$((sum_granted+g));; esac
done < <(RC --scan --pattern 'kong:rl:*:lease:*' </dev/null)
report "$(eq "$sum_granted" 100)" "global sum(granted)=$sum_granted == limit (10 + 9x10; no over-grant)"
g1b=$(RC HGET "$L1" granted </dev/null | tr -d '\r')
s1b=$(RC HGET "$L1" status </dev/null | tr -d '\r')
c1b=$(RC HGET "$L1" created_at </dev/null | tr -d '\r')
report "$(eq "$g1b$s1b$c1b" "$g1$s1$c1")" "L1 record untouched (granted/status/created_at unchanged => no RETURN, no compensation, no takeover)"
bkey=$(RC --scan --pattern 'kong:rl:{'"$NS"':p=*' </dev/null | head -1)
tok=$(RC HGET "$bkey" tokens </dev/null | tr -d '\r')
report "$(awk -v t="$tok" 'BEGIN{print (t<1)?"true":"false"}')" "bucket tokens final=$tok < 1 (all 100 granted tokens digested: 90 allowed + 6 lost + 4 pre-crash)"

echo ""
echo "================ Lease ledger (real data) ================"
echo "Crashed Worker W (PID=$wpid, lease=$lid1):"
echo "  granted=10 (Redis record) = consumed 4 (4x200 pre-crash) + outstanding 6 (remaining sequence 9,8,7,6 => pre-crash)"
echo "  After crash: granted=10 = consumed 4 + lost 6 (outstanding 6 classified as lost, no return, no compensation)"
echo "Other Workers: granted=$((sum_granted-10)) = consumed $p200 + outstanding 0"
echo "Global: sum(granted)=$sum_granted = HTTP allowed $((4+p200)) + lost 6 (no takeover: 94 != 100)"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
