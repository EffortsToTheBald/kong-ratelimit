#!/usr/bin/env bash
# E5: IP dimension trust semantics regression — forged X-Forwarded-For must not create new buckets (P0-3 / D6)
#
# Background: the ip dimension value = kong.client.get_forwarded_ip() = remote_addr after realip processing.
# With the default deployment (trusted_ips unset = trust none) nginx realip does not rewrite remote_addr,
# so the ip value is just the directly connected TCP peer IP — a client-forged XFF is an ordinary request
# header and does not participate in the rate-limit key.
#
# Expected: N requests from the same source IP, each with a different forged XFF → only the 1st passes, all others 429.
# (If that behavior breaks, the ip dimension is trusting forwarded headers from an untrusted source.)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

N=20
assert_prerequisites

NS="rl-xff-$(date +%s)-$$"
log "deploying config: limit=1 window=3600 batch=1 namespace=$NS"
apply_config "$(kong_config_json 1 3600 1 true "$NS")"
sleep 2

log "driving traffic: $N requests, each with a different forged X-Forwarded-For"
codes=""
for i in $(seq 1 "$N"); do
    c=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "X-Forwarded-For: 10.255.$((i / 250)).$((i % 250 + 1))" \
        http://localhost:8030/echo)
    codes="$codes $c"
done
echo "status code sequence: $codes"

ok200=$(echo "$codes" | tr ' ' '\n' | grep -c '^200$' || true)
r429=$(echo "$codes" | tr ' ' '\n' | grep -c '^429$' || true)
echo "200=$ok200  429=$r429  total=$N"

if [ "$ok200" -eq 1 ] && [ "$r429" -eq "$((N - 1))" ]; then
    ok "PASS: forged XFF created no new buckets (all hits on the same IP bucket)"
else
    die "FAIL: 200=$ok200 429=$r429 (forged XFF may be bypassing, or other unexpected status codes appeared)"
fi
