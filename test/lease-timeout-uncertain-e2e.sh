#!/usr/bin/env bash
# ============================================================
# lease-timeout-uncertain-e2e.sh —— 6.5 test 4: Redis timeout and uncertain outcomes
#
# Three cases strictly distinguished (must not be conflated):
#   P1 Redis paused while confirmed stock exists: local TAKE works (confirmed stock is still consumable);
#      stock exhausted ⇒ the new GRANT enters the existing fault branch (503, not 429)
#   A Redis did not execute the GRANT (PAUSE WRITE interception + CLIENT KILL drops it, deterministically not executed):
#      503 ⇒ record count==0 ⇒ subsequent requests GRANT normally
#   B Redis executed but the response was lost (SIGSTOP freeze + Kong timeout closes the connection + after SIGCONT
#      Redis consumes the kernel-buffered commands ⇒ really executed, response lost):
#      503 ⇒ no retry (records <=1) ⇒ no registration in the local lease pool (a later request on the same
#      Worker gets rem=9 and the record count +1) ⇒ the later independent request re-requests via the normal flow
#   granted=0 (explicit rejection ⇒ 429) is covered by quota.sh b20 / concurrent-lease-e2e
# Frozen basis: uncertain outcomes do not retry, do not register in the local lease pool, are not treated as granted=0;
#          it must not be required that the Redis record count is 0 after a timeout (the B scenario has exactly 1 record)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0; NOTV=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
notv() { printf '\033[33m%s\033[0m\n' "$*" >&2; NOTV=$((NOTV+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
RCW() { timeout 15 docker compose exec -T redis redis-cli "$@"; }
PROXY="http://localhost:8030"
NS1="p65t1$$"; NS2="p65t2$$"; NS3="p65t3$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

RC PING >/dev/null || { bad "Redis unavailable"; exit 1; }
cat <<EOF > /tmp/opencode/p65t-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"tmo1","paths":["/tmo1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS1",
     "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"tmo2","paths":["/tmo2"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS2",
     "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"tmo3","paths":["/tmo3"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS3",
     "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65t-config.json >/dev/null \
    || { bad "node :$n config push failed"; exit 1; }
done
ok "config pushed: three routes batch=10 ft=false timeout=1000 window=86400"

http_req() { # $1=fd $2=path ⇒ "status remaining"
  printf 'GET /%s HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n' "$2" >&"$1" || { echo "ERR send"; return; }
  local line status="" rem="" cl=0
  read -r -t 10 line <&"$1" || { echo "ERR read"; return; }
  status=$(printf '%s' "$line" | awk '{print $2}')
  while IFS= read -r -t 10 line <&"$1"; do
    line=${line%$'\r'}
    [ -z "$line" ] && break
    case "$line" in
      Content-Length:*) cl=${line#*: } ;;
      X-RateLimit-Remaining:*) rem=${line#*: } ;;
    esac
  done
  if [ "${cl:-0}" -gt 0 ] 2>/dev/null; then
    IFS= read -r -N "$cl" -t 10 body <&"$1" || true
  fi
  echo "$status ${rem:-NA}"
}
lease_count() { # $1=ns ⇒ record count
  RC --scan --pattern 'kong:rl:*:lease:*' </dev/null | while IFS= read -r k; do
    [ -n "$k" ] || continue
    pk=$(RC HGET "$k" pool_key </dev/null)
    case "$pk" in *"$1"*) echo x;; esac
  done | wc -l | tr -d ' '
}
wait_unpause() { # during PAUSE even PING is blocked ⇒ block until it is lifted, then return
  RCW PING >/dev/null
}

# ================= P1: PAUSE while confirmed stock exists + GRANT fault branch after exhaustion =================
exec 3<>/dev/tcp/127.0.0.1/8030
out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "P1 req1 ⇒ 200 remaining=$rm (GRANT L1, establishes confirmed stock)"
RC CLIENT PAUSE 4000 >/dev/null
ok "CLIENT PAUSE 4000 (P1 window starts)"
p1ok=true; seqexp="8 7 6 5 4 3 2 1 0"; seqgot=""
for i in 2 3 4 5 6 7 8 9 10; do
  out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
  seqgot="$seqgot $rm"
  [ "$st" = "200" ] || p1ok=false
done
report "$p1ok" "P1 req2-10 ⇒ all 200 (confirmed stock is still locally consumable while Redis is paused)"
report "$(eq "${seqgot# }" "$seqexp")" "P1 remaining sequence=${seqgot# } (local TAKE consumes down to 0 one by one; unrelated to Redis)"
out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
report "$(eq "$st" "503")" "P1 req11 after stock exhausted ⇒ $st (new GRANT timeout ⇒ existing fault branch; not 429, no retry)"
wait_unpause
ok "P1 window ended (PING reachable)"
out=$(http_req 3 tmo1); st=${out%% *}; rm=${out#* }
report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "P1 post-recovery request ⇒ 200 remaining=$rm (normal new GRANT L2)"
exec 3>&- 3<&-

# ================= A: Redis did not execute the GRANT (PAUSE WRITE + CLIENT KILL) =================
# PAUSE WRITE: EVALSHA (a write command) is intercepted and queued, while CLIENT LIST/KILL (management
# commands) remain usable;
# at 0.5s Kong's Redis connection is killed (before Kong's 1s timeout) ⇒ EOF ⇒ deterministic fault branch;
# queued commands are dropped with the connection buffer ⇒ Redis deterministically did not execute ⇒ record count==0.
exec 4<>/dev/tcp/127.0.0.1/8030
RC CLIENT PAUSE 5000 WRITE >/dev/null
ok "A: CLIENT PAUSE 5000 WRITE (EVALSHA intercepted and queued, management commands usable)"
curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/tmo3" > /tmp/opencode/p65t-a.txt &
curlpid=$!
sleep 0.5
killed=0
for a in $(RC CLIENT LIST </dev/null | grep -o 'addr=172\.18\.[0-9.]*:[0-9]*' | cut -d= -f2 | sort -u); do
  RC CLIENT KILL ADDR "$a" </dev/null | grep -q '1$\|OK' && killed=$((killed+1))
done
wait $curlpid
stA=$(cat /tmp/opencode/p65t-a.txt)
report "$(eq "$stA" "503")" "A request ⇒ $stA (connection killed ⇒ deterministic fault branch; not 429)"
report "$([ "$killed" -ge 1 ] && echo true)" "A executed CLIENT KILL x$killed (before Kong's timeout; the queued EVALSHA is dropped with the connection ⇒ Redis deterministically did not execute)"
RC CLIENT UNPAUSE >/dev/null 2>&1 || true
ok "A: UNPAUSE (read commands were usable all along in WRITE mode)"
nA=$(lease_count "$NS3")
report "$(eq "$nA" 0)" "A lease record count for this ns=$nA (exactly 0: the command never executed — the key distinction from scenario B)"
out=$(http_req 4 tmo3); st=${out%% *}; rm=${out#* }
report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "A post-recovery request ⇒ $st remaining=$rm (normal new GRANT, no phantom stock)"
exec 4>&- 4<&-

# ================= B: Redis executed but the response was lost (SIGSTOP/SIGCONT) =================
# PAUSE cannot produce "executed but response lost": after Kong's timeout (1s) the cosocket closes and
# the queued commands are dropped (measured records=0). Instead use SIGSTOP/SIGCONT: after the request
# is sent, freeze Redis (commands sit unprocessed in the kernel buffer); Kong's 1s timeout ⇒ 503 and
# the redis cosocket closes; after CONT, Redis consumes the buffered commands ⇒ really executed
# (records=1), and the response is written to the already-closed cosocket ⇒ lost.
# Worker attribution evidence: the timed-out request and the later request share the same fd5 keepalive
# client connection;
# connection -> /proc/net/tcp inode -> worker fd -> PID unique mapping, verified twice consistently
# ⇒ both requests were indeed handled by the same Worker (not merely the same Kong node).
# Acceptance: 503 (uncertain enters the fault branch) ⇒ exactly 1 record (no retry) ⇒ the same Worker's
# later request has remaining=9 and the record count +1 (the uncertain outcome was not registered in the
# local lease pool; a new Lease is requested via the normal flow).
# If Kong closed the client connection after the 503 (fd5 inode disappears), the same-Worker claim cannot
# be proven ⇒ mark NOT VERIFIED, without lowering the acceptance standard.
exec 5<>/dev/tcp/127.0.0.1/8030 || { bad "B: cannot establish the fd5 keepalive connection"; exit 1; }
sleep 0.5
inodeB=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | awk '{print $10}' | sort | uniq -c | awk '$1==1{print $2}' | head -1)
nconn=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -icE ':1F40 ' || true)
report "$(eq "$nconn" 1)" "B fd5 connection unique (ESTAB client connection count=$nconn, inode=$inodeB)"
wpidB=""
for pid in $(docker compose exec -T kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
  if docker compose exec -T kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inodeB\]'" </dev/null; then
    wpidB="$wpidB $pid"
  fi
done
report "$(eq "$(echo $wpidB | wc -w | tr -d ' ')" 1)" "B fd5 owner Worker PID unique=[$wpidB] (inode->fd->PID evidence)"
# STOP first, then send the request (deterministic). Note: sending a default-disposition signal (SIGSTOP)
# from inside the PID namespace to PID 1 is dropped by the kernel — the signal must be sent from the host
# to the container init process's host PID (only signals from outside the namespace take effect).
# The host is not root ⇒ send the namespace-external signal via a --pid host + privileged busybox.
RPID=$(docker inspect kong-ratelimit-redis-1 --format '{{.State.Pid}}')
docker run --rm --pid host --privileged busybox kill -STOP "$RPID" && echo "B: SIGSTOP redis (host PID=$RPID, state T)"
out=$(http_req 5 tmo2); stB=${out%% *}; rmB=${out#* }
report "$(eq "$stB" "503")" "B timed-out request (via fd5, Worker=[$wpidB]) ⇒ $stB (uncertain outcome enters the fault branch; not 429, no blind retry — single request, single failure)"
# after the 503, verify the fd5 client connection is still alive and its owner unchanged (no reuse assumed);
# if Kong closed the client connection ⇒ the same-Worker claim cannot be proven ⇒ later assertions marked
# NOT VERIFIED (standard not lowered)
inodeB2=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
  | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | awk '{print $10}' | sort | uniq -c | awk '$1==1{print $2}' | head -1)
survived=false; wpidB2=""
if [ -n "$inodeB2" ] && [ "$inodeB2" = "$inodeB" ]; then
  for pid in $(docker compose exec -T kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
    if docker compose exec -T kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inodeB2\]'" </dev/null; then
      wpidB2="$wpidB2 $pid"
    fi
  done
  [ "$wpidB2" = "$wpidB" ] && survived=true
fi
report "$survived" "B fd5 still alive after the 503 with unchanged owner (same inode, Worker PID=[$wpidB2])"
docker run --rm --pid host --privileged busybox kill -CONT "$RPID" && echo "B: SIGCONT (Redis consumes the buffered commands ⇒ really executed, response lost)"
sleep 0.5
nB1=$(lease_count "$NS2")
report "$(eq "$nB1" 1)" "B lease record count for this ns=$nB1 (exactly 1: really executed and executed exactly once; a retry would give >=2 ⇒ FAIL)"
if [ "$survived" = "true" ]; then
  out=$(http_req 5 tmo2); st=${out%% *}; rm=${out#* }
  report "$([ "$st" = "200" ] && [ "$rm" = "9" ] && echo true)" "B later request (same fd5, same Worker PID=[$wpidB2]) ⇒ $st remaining=$rm (the uncertain outcome was not registered in the local lease pool — if registered, the same Worker would give rem=8 with no new record)"
  nB2=$(lease_count "$NS2")
  report "$(eq "$nB2" $((nB1+1)))" "B record increment=+$((nB2-nB1)) (the same Worker's later independent request re-requests a new Lease via the normal flow, not reusing the uncertain outcome)"
  inodeB3=$(docker compose exec -T kong1 sh -c 'cat /proc/net/tcp /proc/net/tcp6' </dev/null \
    | awk 'NR>1 && $4=="01"' | grep -iE ':1F40 ' | awk '{print $10}' | sort | uniq -c | awk '$1==1{print $2}' | head -1)
  wpidB3=""
  if [ -n "$inodeB3" ] && [ "$inodeB3" = "$inodeB" ]; then
    for pid in $(docker compose exec -T kong1 sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | awk "{print \$1}"' </dev/null); do
      if docker compose exec -T kong1 sh -c "ls -l /proc/$pid/fd 2>/dev/null | grep -q 'socket:\[$inodeB3\]'" </dev/null; then
        wpidB3="$wpidB3 $pid"
      fi
    done
  fi
  report "$([ "$inodeB3" = "$inodeB" ] && [ "$wpidB3" = "$wpidB" ] && echo true || echo false)" "B fd5 owner consistent throughout (same inode, Worker PID=[$wpidB3] ⇒ the timed-out request and the later request were indeed handled by the same Worker, not merely the same node)"
else
  notv "B same-Worker attribution: Kong closed the fd5 client connection after the 503 (inode gone); cannot prove the timed-out request and the later request share a Worker — marked NOT VERIFIED per the acceptance basis"
fi
exec 5>&- 5<&-

printf '\n===== Summary: PASS=%s FAIL=%s NOT_VERIFIED=%s =====\n' "$PASS" "$FAIL" "$NOTV"
[ "$FAIL" = "0" ]
