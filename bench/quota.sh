#!/usr/bin/env bash
# E1/E2: quota correctness — three nodes sharing one pool
#
#   ./quota.sh -l 100 -b 1  -p 150   # expect exactly 100 passing
#   ./quota.sh -l 100 -b 20 -p 150   # expect within [40, 100]
#
# window defaults to 3600 so that "refill" is negligible within tens of seconds;
# otherwise a few tokens get refilled every second and the result is no longer an integer.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

LIMIT=100
BATCH=1
WINDOW=3600
PER_NODE=150

usage() {
    sed -n '2,8p' "$0"
    cat <<'EOF'
Options:
  -l  limit      quota per window (default 100)
  -b  batch      tokens taken from Redis per call, 0=auto (default 1)
  -w  window     window in seconds (default 3600)
  -p  per_node   hits per node (default 150)
EOF
}

while getopts "l:b:w:p:h" opt; do
    case "$opt" in
        l) LIMIT="$OPTARG" ;;
        b) BATCH="$OPTARG" ;;
        w) WINDOW="$OPTARG" ;;
        p) PER_NODE="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

assert_prerequisites

NODE_COUNT=${#PROXY_NODES[@]}
TOTAL=$(( PER_NODE * NODE_COUNT ))

# P0-6: independent namespace per round, preventing leftover state from the previous round polluting this round
NS="rl-$(date +%s)-$$"
log "deploying config: limit=$LIMIT window=$WINDOW batch=$BATCH namespace=$NS"
apply_config "$(kong_config_json "$LIMIT" "$WINDOW" "$BATCH" true "$NS")"
sleep 2

log "driving traffic: ${NODE_COUNT} nodes x ${PER_NODE} = ${TOTAL} requests"
NODES_CSV=$(IFS=,; printf '%s' "${PROXY_NODES[*]}")
OUT=$(run_k6 k6/quota.js "quota-b${BATCH}.json" \
        "NODES=$NODES_CSV" "ITER=$TOTAL" "VUS=30")

ALLOWED=$(json_num "$OUT" rl_allowed count); ALLOWED=${ALLOWED%.*}
LIMITED=$(json_num "$OUT" rl_limited count); LIMITED=${LIMITED%.*}
OTHER=$(json_num "$OUT" rl_other count);     OTHER=${OTHER%.*}

# P0-5 runtime assertion: each node's request count must strictly equal PER_NODE
assert_per_node_counts "$OUT" "$PER_NODE"

echo
echo "Result: allowed=$ALLOWED  limited=$LIMITED  other=$OTHER  total=$TOTAL"

if [ "$OTHER" -gt 0 ]; then
    warn "got non-200/429 responses ($OTHER), check the logs first: docker compose logs kong1"
fi

if [ "$BATCH" -le 1 ]; then
    if [ "$ALLOWED" -eq "$LIMIT" ]; then
        ok "PASS: exactly the quota $LIMIT (globally consistent)"
    else
        printf '\033[31mFAIL: expected %s, got %s\033[0m\n' "$LIMIT" "$ALLOWED"
        cat <<'EOF'
Triage order:
  1) Did all three nodes receive the config (check the "deploy failed" warnings above)
  2) Are all nodes writing the same Redis key (redis-cli KEYS 'kong:rl:*')
  3) Is a too-small window refilling tokens during the run (use -w 3600)
EOF
        exit 1
    fi
else
    LOWER=$(( LIMIT - NODE_COUNT * BATCH ))
    [ "$LOWER" -lt 0 ] && LOWER=0

    if [ "$ALLOWED" -gt "$LIMIT" ]; then
        printf '\033[31mFAIL: overshot! allowed=%s > limit=%s\033[0m\n' "$ALLOWED" "$LIMIT"
        cat <<'EOF'
This should not happen. Possible causes:
  - The Lua script was modified
  - Inventory did not expire across the window (check store.fill's TTL)
  - limit is not actually in effect (config was not deployed successfully)
EOF
        exit 1
    elif [ "$ALLOWED" -ge "$LOWER" ]; then
        PCT=$(awk -v a="$ALLOWED" -v l="$LIMIT" 'BEGIN{printf "%.1f", a*100/l}')
        ok "PASS: within [$LOWER, $LIMIT], utilization ${PCT}% (under-shot by $(( LIMIT - ALLOWED )))"
    else
        printf '\033[33mBelow the theoretical lower bound: allowed=%s < %s\033[0m\n' "$ALLOWED" "$LOWER"
        cat <<'EOF'
Extra tokens got stuck. Most common causes:
  - lua_shared_dict not in effect, degraded to "one inventory per worker" (worker count x batch all stuck)
  - Check docker compose logs kong1 | grep -i shared
EOF
    fi
fi
