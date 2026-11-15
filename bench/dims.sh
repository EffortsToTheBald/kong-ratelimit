#!/usr/bin/env bash
# E6: multi-dimension rate-limit verification across all dimensions (Phase 2 · multi-dimension ADDED requirements)
#
# Usage: ./bench/dims.sh
#
# Notes:
#   - Each scenario gets its own namespace + FLUSHDB; batch=1 everywhere (bypasses local inventory, eliminates residue interference)
#   - The consumer scenario ships its own full declarative config with key-auth + two consumers + anonymous (kong.yml untouched)
#   - After the run the last config round stays in the runtime (later quota.sh/matrix.sh overwrite it wholesale; no lasting impact)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PASS=0
FAIL=0
report() { # report <true|false> <description>
    if [ "$1" = "true" ]; then
        ok "PASS: $2"
        PASS=$((PASS + 1))
    else
        warn "FAIL: $2"
        FAIL=$((FAIL + 1))
    fi
}
fresh() {
    docker compose exec -T redis redis-cli FLUSHDB >/dev/null
}
code() { # code <url> [curl args...]
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' "$@" "$url"
}
seq_eq() { # seq_eq "<expected string e.g. 200200429>" "<actual string>"
    [ "$2" = "$1" ]
}
dexec() { # unified entry point for commands inside the redis container
    docker compose exec -T redis "$@"
}

echo "===== Scenario 1/7: [ip, path] two paths counted independently ====="
NS="dims-ip-path"
apply_config "$(kong_config_json 2 3600 1 true "$NS" '["ip","path"]')" >/dev/null
sleep 2; fresh
R=""
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo/foo)"
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo/foo)"
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo/foo)"
echo "status code sequence: $R (expected 200200200200429429)"
report "$(seq_eq "200200200200429429" "$R" && echo true || echo false)" "[ip,path] two paths each with an independent quota"

echo "===== Scenario 2/7: [method] GET/POST separate buckets ====="
NS="dims-method"
apply_config "$(kong_config_json 1 3600 1 true "$NS" '["method"]')" >/dev/null
sleep 2; fresh
R=""
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo -X POST)"
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo -X POST)"
echo "status code sequence: $R (expected 200200429429)"
report "$(seq_eq "200200429429" "$R" && echo true || echo false)" "[method] GET/POST each with an independent quota"

echo "===== Scenario 3/7: [header] two tenants + missing-value sentinel ====="
NS="dims-header"
# The header dimension needs header_name (entity_check rejects a config missing it) — build the full config with python
CFG=$(python3 - "$NS" <<'PY'
import json, sys
rl = {"limit": 1, "window": 3600, "batch": 1, "limit_by": ["header"],
      "header_name": "X-Tenant", "namespace": sys.argv[1],
      "redis": {"host": "redis", "port": 6379, "database": 0, "timeout": 1000}}
print(json.dumps({"_format_version": "3.0", "services": [{
    "name": "echo", "url": "http://echo:5678",
    "routes": [{"name": "echo-route", "paths": ["/echo"], "strip_path": False,
                "plugins": [{"name": "rate-limit-advanced", "config": rl}]}]}]}))
PY
)
apply_config "$CFG" >/dev/null
sleep 2; fresh
R=""
R+="$(code http://localhost:8030/echo -H "X-Tenant: a")"
R+="$(code http://localhost:8030/echo -H "X-Tenant: b")"
R+="$(code http://localhost:8030/echo -H "X-Tenant: a")"
R+="$(code http://localhost:8030/echo -H "X-Tenant: b")"
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo)"
echo "status code sequence: $R (expected 200200429429200429)"
report "$(seq_eq "200200429429200429" "$R" && echo true || echo false)" "[header] different header values get separate buckets, missing value gets an independent sentinel bucket"

echo "===== Scenario 4/7: [route] key contains route.id ====="
NS="dims-route"
apply_config "$(kong_config_json 1 3600 1 true "$NS" '["route"]')" >/dev/null
sleep 2; fresh
R="R1=$(code http://localhost:8030/echo) R2=$(code http://localhost:8030/echo)"
echo "$R (expected R1=200 R2=429)"
KEYS=$(dexec redis-cli KEYS "kong:rl:*$NS*")
echo "keys: $KEYS"
route_ok=$(echo "$KEYS" | grep -qE 'route=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' && echo true || echo false)
seq_ok=$(seq_eq "R1=200 R2=429" "$R" && echo true || echo false)
report "$([ "$route_ok" = "true" ] && [ "$seq_ok" = "true" ] && echo true || echo false)" "[route] key contains the route UUID and counts per route"

echo "===== Scenario 5/7: [service] key contains service.id ====="
NS="dims-service"
apply_config "$(kong_config_json 1 3600 1 true "$NS" '["service"]')" >/dev/null
sleep 2; fresh
R="S1=$(code http://localhost:8030/echo) S2=$(code http://localhost:8030/echo)"
echo "$R (expected S1=200 S2=429)"
KEYS=$(dexec redis-cli KEYS "kong:rl:*$NS*")
echo "keys: $KEYS"
svc_ok=$(echo "$KEYS" | grep -qE 'service=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' && echo true || echo false)
seq_ok=$(seq_eq "S1=200 S2=429" "$R" && echo true || echo false)
report "$([ "$svc_ok" = "true" ] && [ "$seq_ok" = "true" ] && echo true || echo false)" "[service] key contains the service UUID and counts per service"

echo "===== Scenario 6/7: [consumer] key-auth two consumers + anonymous ====="
NS="dims-consumer"
CFG=$(python3 - "$NS" <<'PY'
import json, sys
ns = sys.argv[1]
redis = {"host": "redis", "port": 6379, "database": 0, "timeout": 1000}
rl = {"limit": 1, "window": 3600, "batch": 1, "limit_by": ["consumer"], "namespace": ns, "redis": redis}
anon_id = "33333333-3333-3333-3333-333333333333"
print(json.dumps({
    "_format_version": "3.0",
    "consumers": [
        {"username": "alice", "id": "11111111-1111-1111-1111-111111111111",
         "keyauth_credentials": [{"key": "alice-key"}]},
        {"username": "bob",   "id": "22222222-2222-2222-2222-222222222222",
         "keyauth_credentials": [{"key": "bob-key"}]},
        {"username": "anon-visitor", "id": anon_id},
    ],
    "services": [{
        "name": "echo", "url": "http://echo:5678",
        "routes": [{
            "name": "echo-auth", "paths": ["/auth"], "strip_path": False,
            "plugins": [
                {"name": "key-auth", "config": {"anonymous": anon_id}},
                {"name": "rate-limit-advanced", "config": rl},
            ],
        }],
    }],
}))
PY
)
apply_config "$CFG" >/dev/null
sleep 2; fresh
R=""
R+="$(code http://localhost:8030/auth -H "apikey: alice-key")"
R+="$(code http://localhost:8030/auth -H "apikey: alice-key")"
R+="$(code http://localhost:8030/auth -H "apikey: bob-key")"
R+="$(code http://localhost:8030/auth -H "apikey: bob-key")"
R+="$(code http://localhost:8030/auth)"
R+="$(code http://localhost:8030/auth)"
echo "status code sequence: $R (expected 200429200429200429)"
report "$(seq_eq "200429200429200429" "$R" && echo true || echo false)" "[consumer] alice/bob/anon each with an independent quota"
ERRS=$(docker compose logs kong1 --since 3m 2>/dev/null | grep -c "attempt to call" || true)
report "$([ "$ERRS" = "0" ] && echo true || echo false)" "consumer scenario has no Lua call errors (attempt to call=$ERRS, key-auth runs before rate limiting)"

echo "===== Scenario 7/7: dimension order ⇒ different fingerprints ====="
F1=$(docker compose exec -T kong1 resty -e '
local a = require "kong.plugins.rate-limit-advanced.lib.algorithm"
io.write(a.policy_fingerprint{limit=100, window=3600, burst=0, batch=1, limit_by={"ip","path"}, namespace="x", redis={key_prefix="kong:rl"}})
')
F2=$(docker compose exec -T kong1 resty -e '
local a = require "kong.plugins.rate-limit-advanced.lib.algorithm"
io.write(a.policy_fingerprint{limit=100, window=3600, burst=0, batch=1, limit_by={"path","ip"}, namespace="x", redis={key_prefix="kong:rl"}})
')
echo "order[ip,path]=$F1  order[path,ip]=$F2"
report "$([ -n "$F1" ] && [ "$F1" != "$F2" ] && echo true || echo false)" "different dimension order ⇒ different fingerprint ⇒ different buckets"

echo
echo "===== dims summary: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || die "there are failed scenarios"
ok "all dimension scenarios passed"
