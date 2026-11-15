#!/usr/bin/env bash
# ============================================================
# redis-password-e2e.sh -- Gate 6 Task 2: redis.password end-to-end verification
#
# Coverage (Kong 3.6 OSS, schema password = encrypted+referenceable+len_min=0):
#   A. Plaintext password + AUTH: temporary Redis(:6380, requirepass) authorizes and allows 200
#   B. Wrong password: AUTH fails => Fail-close 503 (fault_tolerant=false)
#   C. Vault reference: password = {vault://env/kong-log-level} (resolves to the
#      KONG_LOG_LEVEL=notice environment variable inside the kong container, built-in env vault of Kong 3.6)
#      => reference resolvable and authorization allows 200
# Precondition: docker compose up -d (redis + kong1 healthy); the temporary Redis is
#       started inside the redis container on port 6380, and is shut down for cleanup at the end of the script.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }

# ---- Precondition ----
docker compose exec -T redis redis-cli ping >/dev/null 2>&1 || { bad "Redis unavailable"; exit 1; }

# ---- Restart kong1 to load the new schema (schema.lua is part of the plugin code; POST /config only rebuilds
#      the iterator, not the Lua VM, so a restart is required for encrypted/referenceable to take effect) ----
docker compose restart kong1 >/dev/null 2>&1
for i in $(seq 1 30); do
  curl -fsS --max-time 2 "http://localhost:8031/status" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 5 "http://localhost:8031/status" >/dev/null \
  || { bad "kong1 not ready after restart"; exit 1; }
ok "precondition: kong1 restarted (new schema loaded)"

# ---- Start temporary Redis (:6380, password = notice, matching KONG_LOG_LEVEL for Case C resolution) ----
docker compose exec -d redis sh -c 'redis-server --port 6380 --requirepass notice --save "" --appendonly no' </dev/null
sleep 1
cleanup() {
  docker compose exec -T redis sh -c 'redis-cli -p 6380 -a notice shutdown nosave >/dev/null 2>&1 || true' </dev/null
}
trap cleanup EXIT
docker compose exec -T redis sh -c 'redis-cli -p 6380 -a notice ping' </dev/null 2>/dev/null | grep -q PONG \
  || { bad "temporary Redis(:6380) failed to start"; exit 1; }
ok "precondition: temporary Redis :6380 (requirepass) started"

push_cfg() { # push_cfg <ns> <password-json-value>
  local ns="$1" pw="$2"
  cat <<EOF > /tmp/opencode/pw-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"pw","paths":["/pw-$ns"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$ns",
   "window":86400,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],
   "fault_tolerant":false,
   "redis":{"host":"redis","port":6380,"database":0,"timeout":1000,"password":$pw}}}]}]}]}
EOF
  curl -fsS --max-time 10 -X POST "http://localhost:8031/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/pw-config.json >/dev/null \
    && return 0 || return 1
}

hit() { # hit <path> -- returns http_code
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://localhost:8030$1"
}

wait_code() { # wait_code <path> <expected> -- after POST /config triggers a reload, old and new Workers coexist briefly
  local expected="$2" code
  for _ in $(seq 1 15); do
    code=$(hit "$1")
    if [ "$code" = "$expected" ]; then echo "$code"; return 0; fi
    sleep 1
  done
  echo "$code"
}

# ---- Case A: vault reference (referenceable end-to-end) ----
if push_cfg "pwvault$$" '"{vault://env/kong-log-level}"'; then
  code=$(wait_code "/pw-pwvault$$" 200)
  if [ "$code" = "200" ]; then
    ok "Case A: password={vault://env/kong-log-level} resolved successfully and AUTH allowed (HTTP=200)"
  else
    bad "Case A: vault reference resolution/authorization failed (HTTP=$code)"
  fi
else
  bad "Case A: Admin API rejected the vault reference (referenceable not in effect)"
fi

# ---- Case B: plaintext password happy path ----
if push_cfg "pwplain$$" '"notice"'; then
  code=$(wait_code "/pw-pwplain$$" 200)
  if [ "$code" = "200" ]; then
    ok "Case B: plaintext password AUTH allowed (HTTP=200)"
  else
    bad "Case B: plaintext password authorization failed (HTTP=$code)"
  fi
else
  bad "Case B: Admin API rejected the plaintext password config"
fi

# ---- Case C: wrong password => Fail-close 503 (never disguised as 429) ----
if push_cfg "pwwrong$$" '"wrong-pass"'; then
  code=$(wait_code "/pw-pwwrong$$" 503)
  if [ "$code" = "503" ]; then
    ok "Case C: wrong password => Fail-close 503 (existing failure semantics)"
  else
    bad "Case C: wrong password did not return 503 (HTTP=$code)"
  fi
else
  bad "Case C: Admin API rejected the wrong-password config (should be accepted, failing at runtime only)"
fi

printf '\n===== Summary: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
