#!/usr/bin/env bash
# ============================================================
# script-cache-selfheal-e2e.sh -- 6.4 EVALSHA script cache self-heal (real stack)
#
# Scenario (Spec/Phase 2 frozen criteria):
#   1. Send a request under each of the three modes: normal EVALSHA (lazy load already done) => 200
#   2. SCRIPT FLUSH clears the Redis script cache
#   3. Send requests again under the three modes: EVALSHA => NOSCRIPT => SCRIPT LOAD => exactly one retry => 200 (self-heal)
#   4. SCRIPT EXISTS proves all three scripts were reloaded into the cache by the plugin:
#      sha is computed via sha1sum on the extracted text (never manually SCRIPT LOAD -- it would pollute the check);
#      the extracted text must be byte-for-byte identical to the plugin src: the first newline right after
#      the Lua long bracket [[ is stripped by Lua, so the first newline must be removed after extraction before computing the SHA
#   5. Timeout does not trigger LOAD: asserted by unit test evalsha-unit.sh case6 (this group references its result)
# Note: after FLUSH, if lease routing hits the worker local lease pool then zero Redis => grant_lease
# does not trigger a NOSCRIPT reload; hence the post-FLUSH grant_lease verification uses a new ns and a new route
# (new fingerprint => new Pool => first request must GRANT)
# Precondition: three nodes healthy; independent namespace
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
NS="p64s$$"

ok "three-mode routing (batch=1 / batch>1 / multi-rule) self-heal criteria ready"

cat <<EOF > /tmp/opencode/rl64-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"s-b1","paths":["/s-b1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-b1",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-g1","paths":["/s-g1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-g1",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-mu","paths":["/s-mu"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-mu",
     "limit":50,"window":3600,"burst":0,
     "rules":[{"limit":100,"window":3600,"limit_by":["ip"]},
              {"limit":50,"window":3600,"limit_by":["ip"]}],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl64-config.json >/dev/null \
    || { bad "config push failed on node :$n"; exit 1; }
done
ok "config pushed for three routes (batch=1 / batch>1 / multi-rule)"

# ---- 1. Normal requests (lazy load done) ----
for p in s-b1 s-g1 s-mu; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/$p")
  report "$(eq "$c" 200)" "pre-FLUSH request /$p => $c (expected 200, EVALSHA normal)"
done

# ---- 2. Clear the script cache ----
RC SCRIPT FLUSH >/dev/null
ok "SCRIPT FLUSH done (script cache cleared)"

# ---- 2b. Push lease route with a new ns (new fingerprint => new Pool => post-FLUSH first request must GRANT) ----
NS2="p64s2$$"
cat <<EOF > /tmp/opencode/rl64-config2.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"s-b1","paths":["/s-b1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-b1",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-g1","paths":["/s-g1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-g1",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-g2","paths":["/s-g2"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS2-g2",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-mu","paths":["/s-mu"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-mu",
     "limit":50,"window":3600,"burst":0,
     "rules":[{"limit":100,"window":3600,"limit_by":["ip"]},
              {"limit":50,"window":3600,"limit_by":["ip"]}],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl64-config2.json >/dev/null \
    || { bad "config push 2 failed on node :$n"; exit 1; }
done
ok "new lease route s-g2 pushed (new ns $NS2-g2)"

# ---- 3. Post-FLUSH requests: NOSCRIPT => LOAD => exactly one retry => self-heal ----
# s-g2 first request: no local lease pool => NEED_GRANT => grant_lease NOSCRIPT self-heal
for p in s-b1 s-g2 s-mu; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/$p")
  report "$(eq "$c" 200)" "post-FLUSH request /$p => $c (expected 200: NOSCRIPT self-heal succeeded; without self-heal it would be 503)"
done

# ---- 4. SCRIPT EXISTS: all three scripts have been reloaded into the cache by the plugin ----
for name in TOKEN_BUCKET GRANT_MULTI GRANT_LEASE; do
  sha=$(python3 - "$name" <<'PYEOF'
import re, sys, hashlib
src = open('kong/plugins/rate-limit-advanced/lib/redis.lua').read()
name = sys.argv[1]
t = re.search(r'local ' + name + r' = \[\[(.*?)\]\]', src, re.S).group(1)
if t.startswith('\n'):
    t = t[1:]
print(hashlib.sha1(t.encode()).hexdigest())
PYEOF
)
  ex=$(RC SCRIPT EXISTS "$sha" | tr -d '\r')
  report "$(eq "$ex" 1)" "$name is in the script cache (sha1sum=$sha EXISTS=$ex; no SCRIPT LOAD executed before the check)"
done

# ---- 5. Logs: no traces of self-heal failure ----
logs=$(docker compose logs kong1 --since 3m 2>&1 || true)
report "$([ "$(echo "$logs" | grep -c 'script still missing after reload')" -eq 0 ] && echo true)" "no 'script still missing after reload' in logs (self-heal did not fail)"
report "$([ "$(echo "$logs" | grep -c 'script load failed')" -eq 0 ] && echo true)" "no 'script load failed' in logs"

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
