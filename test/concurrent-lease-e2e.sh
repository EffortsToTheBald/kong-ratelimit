#!/usr/bin/env bash
# ============================================================
# concurrent-lease-e2e.sh —— 6.5 test 1: multi-Worker concurrent TAKE / GRANT
#
# Goal (frozen basis):
#   1. concurrent requests spread across multiple Workers (lease_id = host:worker:seq:hex evidence)
#   2. no global over-grant: sum of granted == limit == 100; HTTP allowed == 100 == sum of granted
#      (the distinction between GRANT-authorized / local TAKE-consumed / HTTP-allowed quantities is in the report)
#   3. concurrent TAKE with no double consumption: all X-RateLimit-Remaining >= 0
#      (remaining = local pool remainder, algorithm.lua:423-424) + allowed == sum of granted
#   4. correct re-request after exhaustion (exhausted ⇒ new GRANT; denied-GRANT granted=0 ⇒ 429)
# Prerequisites: 3 nodes x >=2 Workers; same namespace, same rule, batch=10; window=86400
#      (refill < 0.1 token throughout the test ⇒ does not affect exact accounting)
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
PROXY="http://localhost:8030"
NS="p65c$$"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'

# ---- prerequisite checks ----
RC PING >/dev/null || { bad "Redis unavailable"; exit 1; }
for n in kong1 kong2 kong3; do
  w=$(docker compose exec -T "$n" sh -c 'ps -o pid,cmd | grep "nginx: worker" | grep -v grep | wc -l' </dev/null | tr -d ' ')
  report "$([ "$w" -ge 2 ] && echo true)" "$n Worker count=$w (>=2)"
  case $n in kong1) W_K1=$w;; kong2) W_K2=$w;; kong3) W_K3=$w;; esac
done
ok "prerequisites: Redis PING + Worker count verification on 3 nodes"

# ---- wait for the reload mixing period to end (Gate 4 lesson + review fixes):
# after a kong reload, old Workers coexist briefly; their old-format Lease records and EVALSHA
# counts would create spurious deltas in accounting assertions.
# Review fix 1: pgrep -f can spuriously match the shell executing the command, and "identical
# process counts twice in a row" cannot prove old Workers exited. Instead: enumerate Worker PIDs
# by **prefix**-exact matching of /proc cmdline (a shell's own cmdline starts with "sh -c" ⇒ no
# spurious match), and record the PID set (old generation) **before** the config push.
# Convergence criterion = a single generation:
#   * no reload ⇒ current set == old-generation set (same set);
#   * reload ⇒ all old-generation PIDs exited (the two sets are disjoint).
# If neither can be proven ⇒ the check fails and the script exits with convergence failure
# "cannot prove all old Workers exited", without weakening the evidence strength of accounting assertions.
worker_pids() { # worker_pids <container> —— enumerate Worker PIDs (/proc cmdline prefix match)
    docker compose exec -T "$1" sh -c 'for d in /proc/[0-9]*/cmdline; do
        c=$(head -c 80 "$d" 2>/dev/null | tr "\0" " ")
        case "$c" in "nginx: worker process "*) p=${d%/cmdline}; echo "${p#/proc/}" ;; esac
    done' 2>/dev/null
}
single_generation() { # single_generation <pre_pids space-joined> <cur_pids space-joined>
    [ "$1" = "$2" ] && return 0          # no reload: same set
    local p mixed=0
    for p in $1; do                       # reload: old-generation PID still present ⇒ mixing period
        case " $2 " in *" $p "*) mixed=1 ;; esac
    done
    [ "$mixed" = "0" ]
}
wait_stable() { # wait_stable <container> <pre_pids> —— single generation and two consecutive identical samples
    local k="$1" pre="$2" prev="" cur
    for _ in $(seq 1 30); do
        cur=$(worker_pids "$k" | sort | tr '\n' ' ' | sed 's/ *$//')
        if [ -n "$cur" ] && [ "$cur" = "$prev" ] && single_generation "$pre" "$cur"; then
            return 0
        fi
        prev=$cur
        sleep 1
    done
    return 1
}
PIDS_K1=$(worker_pids kong1 | sort | tr '\n' ' ' | sed 's/ *$//')
PIDS_K2=$(worker_pids kong2 | sort | tr '\n' ' ' | sed 's/ *$//')
PIDS_K3=$(worker_pids kong3 | sort | tr '\n' ' ' | sed 's/ *$//')
# ---- snapshot validity verification (final review fix): non-empty, Workers >=2, count consistent with the prerequisite check ----
# an empty snapshot entering single_generation() would misjudge "empty old generation" as "old generation fully exited";
# if a snapshot cannot be confirmed, fail immediately instead of entering the generation check.
for k in kong1 kong2 kong3; do
  case $k in kong1) snap="$PIDS_K1"; pre_n="$W_K1";; kong2) snap="$PIDS_K2"; pre_n="$W_K2";; kong3) snap="$PIDS_K3"; pre_n="$W_K3";; esac
  wc=$(printf '%s' "$snap" | wc -w | tr -d ' ')
  if [ -z "$snap" ] || [ "$wc" -lt 2 ] || [ "$wc" != "$pre_n" ]; then
    bad "$k old-generation PID snapshot cannot be confirmed (count=$wc pre-check=$pre_n; requires non-empty, >=2, consistent with the prerequisite check) — failing directly"
    exit 1
  fi
  ok "snapshot valid: $k old-generation Worker PID count=$wc (non-empty, >=2, consistent with the prerequisite check)"
done
# ---- config push ----
# (the old-generation Worker PID snapshot must be captured **before** the config push — POST /config may trigger a reload)
cat <<EOF > /tmp/opencode/p65c-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"conc","paths":["/conc"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS",
   "window":86400,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]}]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/p65c-config.json >/dev/null \
    || { bad "node :$n config push failed"; exit 1; }
done
ok "config pushed: limit=100 window=86400 batch=10 ns=$NS (3 nodes)"

for k in kong1 kong2 kong3; do
  case $k in kong1) pre="$PIDS_K1";; kong2) pre="$PIDS_K2";; kong3) pre="$PIDS_K3";; esac
  wait_stable "$k" "$pre" || { bad "$k Worker generation did not converge (cannot prove all old Workers exited, PID set: pre=[$pre])"; exit 1; }
done
ok "Worker generation is single (PID set evidence: no reload means same set, or all old-generation PIDs exited)"

# ---- EVALSHA count snapshot (Gate 3 Plan B: degraded direct-path grants go through TOKEN_BUCKET EVALSHA
#      and produce no Lease record ⇒ must be included in accounting assertions; evidenced by Redis commandstats counts) ----
evalsha_before=$(RC INFO commandstats </dev/null | tr -d '\r' | sed -n 's/^cmdstat_evalsha:calls=//p' | cut -d, -f1)
[ -n "$evalsha_before" ] || evalsha_before=0

# ---- Phase A: 30 concurrent requests (rotating across three nodes, sampling X-RateLimit-Remaining) ----
mkdir -p /tmp/opencode/p65c-h
seq 1 30 | awk -v c=$$ '{print $1}' | while read i; do echo "$i"; done >/dev/null
seq 1 30 | xargs -P 8 -I{} sh -c 'p=$(( {} % 3 )); case $p in 0) u=8030;; 1) u=8010;; 2) u=8020;; esac; curl -s -o /dev/null -D /tmp/opencode/p65c-h/h{} -w "%{http_code}\n" --max-time 8 http://localhost:$u/conc' > /tmp/opencode/p65c-a.txt || true
ok "Phase A: 30 concurrent requests (rotating across three nodes, response headers sampled per request)"

# ---- Phase B: 270 concurrent requests (rotating across three nodes) ----
seq 1 270 | xargs -P 8 -I{} sh -c 'p=$(( {} % 3 )); case $p in 0) u=8030;; 1) u=8010;; 2) u=8020;; esac; curl -s -o /dev/null -w "%{http_code}\n" --max-time 8 http://localhost:$u/conc' > /tmp/opencode/p65c-b.txt || true
ok "Phase B: 270 concurrent requests (rotating across three nodes)"

# ---- Phase C: drain (sequential requests rotating across three nodes until 100 consecutive 429s; cap 600 requests) ----
: > /tmp/opencode/p65c-drain.txt
streak=0; allowed_drain=0
for i in $(seq 1 600); do
  case $(( i % 3 )) in 0) u=8030;; 1) u=8010;; 2) u=8020;; esac
  line=$(curl -s -o /dev/null -D /tmp/opencode/p65c-lasthdr -w '%{http_code}' --max-time 8 "http://localhost:$u/conc")
  echo "$line" >> /tmp/opencode/p65c-drain.txt
  if [ "$line" = "429" ]; then
    streak=$((streak+1))
    [ "$streak" -ge 100 ] && break
  else
    streak=0; allowed_drain=$((allowed_drain+1))
  fi
done
ok "Phase C: drain (100 consecutive 429s or the 500-request cap; additional allowed during drain=$allowed_drain)"

# ---- summary statistics ----
allowed_a=$(grep -c '^200$' /tmp/opencode/p65c-a.txt || true)
denied_a=$(grep -c '^429$' /tmp/opencode/p65c-a.txt || true)
other_a=$(grep -cv '^200$\|^429$' /tmp/opencode/p65c-a.txt || true)
allowed_b=$(grep -c '^200$' /tmp/opencode/p65c-b.txt || true)
denied_b=$(grep -c '^429$' /tmp/opencode/p65c-b.txt || true)
other_b=$(grep -cv '^200$\|^429$' /tmp/opencode/p65c-b.txt || true)
denied_c=$(grep -c '^429$' /tmp/opencode/p65c-drain.txt || true)
other_c=$(grep -cv '^429$' /tmp/opencode/p65c-drain.txt || true)
allowed=$((allowed_a + allowed_b + allowed_drain))
total=$(( $(wc -l < /tmp/opencode/p65c-a.txt) + $(wc -l < /tmp/opencode/p65c-b.txt) + $(wc -l < /tmp/opencode/p65c-drain.txt) ))
other=$((other_a + other_b + other_c))
echo "stats: total=$total allowed=$allowed denied429=$((denied_a+denied_b+denied_c)) other=$other (A:$allowed_a/30 B:$allowed_b/270 C:$allowed_drain)"

# ---- assertion 1: no unexpected status codes ----
report "$(eq "$other" 0)" "no 5xx/other unexpected status codes (other=$other)"

# ---- assertion 2: no global over-grant: allowed == 100 == limit ----
report "$(eq "$allowed" 100)" "HTTP allowed=$allowed (exactly equal to limit=100; no over-grant under concurrency)"

# ---- assertion 3: Redis GRANT record accounting: sum of granted == 100, granted=10 per record ----
records=0; sum_granted=0; workers_seen=""
while IFS= read -r k; do
  [ -n "$k" ] || continue
  pk=$(RC HGET "$k" pool_key </dev/null)
  case "$pk" in *"$NS"*) ;; *) continue ;; esac
  records=$((records+1))
  g=$(RC HGET "$k" granted </dev/null | tr -d '\r')
  sum_granted=$((sum_granted + g))
  lid=$(RC HGET "$k" lease_id </dev/null | tr -d '\r')
  hostw=$(echo "$lid" | cut -d: -f1,2)
  case ",$workers_seen," in *",$hostw,"*) ;; *) workers_seen="$workers_seen,$hostw" ;; esac
done < <(RC --scan --pattern 'kong:rl:*:lease:*' </dev/null)
ndistinct=$(echo "$workers_seen" | tr ',' '\n' | grep -c . || true)
echo "GRANT records: count=$records sum_granted=$sum_granted distinct(host,worker)=$ndistinct [$workers_seen]"

# ---- assertion 3 (Gate 3 Plan B adaptation): Lease sum of granted + direct batch == 100 (evidenced by Redis EVALSHA counts) ----
# EVALSHA delta = Lease GRANT calls (successful record creation=records + denied-GRANT returning granted=0=denied)
#             + degraded direct-path batch=1 TOKEN_BUCKET calls (produce no Lease record).
# ⇒ direct = delta - records - denied. Total grant ledger = sum of granted + direct, still exactly equal to limit=100.
evalsha_after=$(RC INFO commandstats </dev/null | tr -d '\r' | sed -n 's/^cmdstat_evalsha:calls=//p' | cut -d, -f1)
[ -n "$evalsha_after" ] || evalsha_after=0
denied_total=$((denied_a + denied_b + denied_c))
direct=$((evalsha_after - evalsha_before - records - denied_total))
report "$([ "$direct" -ge 0 ] && echo true)" "direct batch=$direct (EVALSHA delta=$((evalsha_after - evalsha_before)) - Lease records=$records - denied-GRANT=$denied_total; >=0)"
total_granted=$((sum_granted + direct))
report "$(eq "$total_granted" 100)" "Redis total grant ledger=$total_granted (Lease sum granted=$sum_granted + direct=$direct; exactly equal to limit=100, no over-grant)"
report "$([ "$sum_granted" -le 100 ] && echo true)" "Lease sum granted=$sum_granted <= limit=100 (Lease accounting does not over-grant)"

# ---- assertion 4: requests spread across multiple Workers ----
report "$([ "$ndistinct" -ge 3 ] && echo true)" "requests spread across $ndistinct distinct (host,worker) >=3 (lease_id host:worker segment evidence)"

# ---- assertion 5: local TAKE with no double consumption: all sampled remaining >= 0 ----
minrem=99999
for f in /tmp/opencode/p65c-h/h* /tmp/opencode/p65c-lasthdr; do
  [ -f "$f" ] || continue
  r=$(sed -n 's/^X-RateLimit-Remaining: //pi' "$f" | tr -d '\r')
  [ -n "$r" ] && [ "$r" -lt "$minrem" ] && minrem=$r
done
report "$([ "$minrem" -ge 0 ] && echo true)" "all sampled X-RateLimit-Remaining >= 0 (min=$minrem; no negative stock / no double consumption in the local pool)"

# ---- assertion 6 (Gate 3 Plan B adaptation): TAKE consumption + direct allowed == HTTP allowed ----
# each 200 corresponds to exactly one unit of stock consumption: Lease TAKE consumption == sum of granted
# (the Lease-side conservation invariant), and each direct batch consumes exactly 1 Redis token (the existing
# batch=1 path); the two ledgers together == allowed.
report "$(eq "$((sum_granted + direct))" "$allowed")" "total consumption ledger=$((sum_granted + direct)) == HTTP allowed=$allowed (Lease TAKE consumption=sum granted=$sum_granted + direct=$direct; no loss, no duplication)"

# ---- assertion 7: post-exhaustion new GRANT semantics (denied-GRANT ⇒ 429, not masked as 503) ----
report "$([ $((denied_a+denied_b+denied_c)) -gt 0 ] && echo true)" "over-quota requests returned 429=$((denied_a+denied_b+denied_c)) (post-exhaustion denied-GRANT granted=0 existing semantics)"

# ---- assertion 8: final bucket tokens < 1 ----
# (SIGPIPE lesson: SCAN|head silently interrupts the script under pipefail ⇒ collect fully before taking the first;
#   new Lease keys share a prefix with the bucket key ⇒ ":lease:" must be excluded, otherwise tokens is empty
#   and the assertion passes vacuously)
mapfile -t _bkts < <(RC --scan --pattern 'kong:rl:{'"$NS"':p=*' </dev/null)
bkey=""
for k in "${_bkts[@]}"; do
  case "$k" in *":lease:"*) ;; *) bkey="$k"; break ;; esac
done
tok=$(RC HGET "$bkey" tokens </dev/null | tr -d '\r')
report "$([ -n "$tok" ] && awk -v t="$tok" 'BEGIN{print (t<1)?"true":"false"}')" "final bucket tokens=$tok < 1 (quota fully digested via GRANT, no leakage; bkey=$bkey)"

printf '\n===== Summary: PASS=%s FAIL=%s NOT_VERIFIED=%s =====\n' "$PASS" "$FAIL" "$NOTV"
[ "$FAIL" = "0" ]
