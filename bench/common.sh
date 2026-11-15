#!/usr/bin/env bash
# ============================================================
# Shared helpers: config deployment, Redis metering, k6 invocation
# Sourced by quota.sh / matrix.sh
# ============================================================
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yml"

PROXY_NODES=("http://localhost:8030" "http://localhost:8010" "http://localhost:8020")
ADMIN_NODES=("http://localhost:8031" "http://localhost:8011" "http://localhost:8021")

log()  { printf '\033[36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

assert_prerequisites() {
    require_cmd docker
    require_cmd k6
    require_cmd curl
    require_cmd python3

    docker compose version >/dev/null 2>&1 \
        || die "docker compose v2 (docker-compose-plugin) required, currently unavailable"

    curl -fsS --max-time 3 "${ADMIN_NODES[0]}/status" >/dev/null 2>&1 \
        || die "kong1 admin plane unreachable; run first: docker compose up -d"
}

# Generate a Kong DB-less declarative config (JSON)
# Usage: kong_config_json <limit> <window> <batch> <with_plugin> [namespace] [limit_by_json]
#   Arg 5 namespace: unique per round/case (passed by quota.sh, matrix.sh), preventing cross-round shared buckets (P0-6)
#   Arg 6 limit_by_json: raw JSON array, default ["ip"]; dims.sh passes ["ip","path"] etc.
#   fault_tolerant explicit false: aligned with the fail-closed default; fault-injection scenarios pass true explicitly
kong_config_json() {
    local limit="$1" window="$2" batch="$3" with_plugin="${4:-true}"
    local ns="${5:-rl}"
    local limit_by="${6:-[\"ip\"]}"
    local rhost="${7:-redis}"   # Redis host (domain or IP; default redis=container DNS)
    local ehost="${8:-echo}"    # Upstream echo host (domain or IP; default echo=container DNS)
    local plugins=""

    if [ "$with_plugin" = "true" ]; then
        plugins=$(cat <<EOF
[{"name":"rate-limit-advanced","config":{
  "limit":${limit},"window":${window},"batch":${batch},
  "limit_by":${limit_by},"namespace":"${ns}","fault_tolerant":false,
  "redis":{"host":"${rhost}","port":6379,"database":0,"timeout":1000}}}]
EOF
)
    else
        plugins="[]"
    fi

    cat <<EOF
{"_format_version":"3.0","services":[{"name":"echo","url":"http://${ehost}:5678",
 "routes":[{"name":"echo-route","paths":["/echo"],"strip_path":false,
 "plugins":${plugins}}]}]}
EOF
}

apply_config() {
    local json="$1" admin
    # In DB-less mode each node holds its own config copy; must deploy to each one
    for admin in "${ADMIN_NODES[@]}"; do
        if ! curl -fsS --max-time 10 -X POST "$admin/config" \
                -H 'Content-Type: application/json' -d "$json" >/dev/null; then
            warn "failed to deploy config to $admin (the node may still be running the old config)"
        fi
    done
}

redis_cmd_count() {
    docker compose -f "$COMPOSE_FILE" exec -T redis \
        redis-cli INFO stats 2>/dev/null \
        | awk -F: '/^total_commands_processed:/{gsub(/[ \r]/,"",$2); print $2; exit}'
}

# Read the k6 summary JSON: json_num <file> <metric> <field>
json_num() {
    python3 - "$@" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print(0)
    raise SystemExit(0)
m = d.get("metrics", {}).get(sys.argv[2], {}).get("values", {})
print(m.get(sys.argv[3], 0))
PY
}

# P0-5 runtime assertion: each node's request count in the summary must strictly equal the expected value.
# If node assignment ever goes out of control (VU binding assumption broken), this round's results cannot serve
# as global quota evidence and must fail hard.
# Usage: assert_per_node_counts <k6_summary.json> <expected_per_node>
assert_per_node_counts() {
    local out="$1" expected="$2" i v
    for i in 1 2 3; do
        v=$(json_num "$out" "requests_kong${i}" count); v=${v%.*}
        if [ "$v" -ne "$expected" ]; then
            die "per-node request count assertion failed: kong${i} got ${v} != expected ${expected} (node assignment out of control; this round's results cannot serve as global quota evidence)"
        fi
    done
    ok "per-node request count assertion passed: kong1/2/3 each ${expected} requests"
}

# Run k6; on success print the artifact path to stdout (k6's own output goes to stderr)
# Usage: run_k6 <script> <out-name> [KEY=VALUE ...]
run_k6() {
    local script="$1" outname="$2"; shift 2
    local outdir="$PROJECT_ROOT/bench/out"
    mkdir -p "$outdir"
    local out="$outdir/$outname"
    rm -f "$out"

    local envargs=()
    local kv
    for kv in "$@"; do envargs+=(-e "$kv"); done

    # k6 occasionally hangs after writing the summary to disk and never exits (Phase 1 triage record) — timeout fallback:
    # if the data has been written, take it and continue; not treated as failure (exit 124)
    set +e
    ( cd "$PROJECT_ROOT" && timeout 60 k6 run --quiet "${envargs[@]}" -e "OUT=$out" "$script" >&2 )
    local k6rc=$?
    set -e
    if [ "$k6rc" -ne 0 ] && [ "$k6rc" -ne 124 ]; then
        die "k6 execution failed (rc=$k6rc)"
    fi
    if [ "$k6rc" -eq 124 ]; then
        warn "k6 hung after writing the summary (killed by the timeout fallback); taking $out and continuing"
    fi

    [ -f "$out" ] || die "k6 produced no $out"
    printf '%s\n' "$out"
}
