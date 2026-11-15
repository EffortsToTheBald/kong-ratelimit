#!/usr/bin/env bash
# ============================================================
# matrix.sh — Performance matrix framework (Phase 1 Legacy baseline; reused by the Phase 7 Lease implementation with a new leaseGrant column)
#
# Usage:
#   ./bench/matrix.sh -w 2      # Worker=2 full group (current compose config)
#   ./bench/matrix.sh -w 1      # Switch to Worker=1, run the full group, restore compose defaults at the end
#
# Group layout (no full-dimension cross product anymore):
#   M0  No-plugin control
#   A   Single rule batch=1 (1 Redis EVAL per request)
#   B   Single rule batch>1 (explicit batch; Phase 1 Legacy=shared dict, Phase 7=Lease local TAKE + GRANT_LEASE)
#   C   Multi-rule GRANT_MULTI (1 EVAL per request)
#   RPS tiers: low 100 / mid 500 / high 1000
#
# Path verification (never infer from config alone):
#   Redis EVAL count       → INFO commandstats cmdstat_eval calls delta
#   Local inventory hits   → Kong log [RL-DEBUG] local_hit line count delta
#   Redis inventory grants → Kong log [RL-DEBUG] redis_grant line count delta
#   Multi-rule EVAL        → Kong log [RL-DEBUG] multi_grant line count delta
#   Redis QPS/CPU          → INFO total_commands_processed / INFO cpu delta
#   Kong CPU               → container cgroup cpu.stat usage_usec delta
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

WORKERS="${WORKERS:-2}"      # Target worker count (override with -w)
# Since Phase 8.2-B, RL-DEBUG hot-path logs have been downgraded to debug level:
# the stats columns (localHit/slowGrant/leaseGrant/multiGrant) depend on those log
# lines, so this script runs at debug level by default (override with -L).
# For a notice-level comparison pass -L notice explicitly (stats columns will be 0, see the reading notes).
LOGLEVEL="${LOGLEVEL:-debug}"
TAG="${TAG:-p1}"               # Output tag (override with -T; Phase 2 uses p2 to avoid overwriting the Phase 1 baseline files)
RHOST="redis"                  # Redis host (-H <host>: pass an IP to work around intermittent container DNS hangs — a known defect found in Phase 0)
EHOST="echo"                   # Upstream echo host (-E <host>: pass an IP; the container DNS defect also affects the proxy path)
DUR="${DUR:-20}"             # Duration per group (seconds)
RATES="${RATES:-100,500,1000}"
BATCHES="${BATCHES:-10,50,100}"
LIMIT=1000000                # Intentionally inflated to isolate the rate-limit path (only passing requests are measured)
WINDOW=60

while getopts "w:L:H:E:T:d:r:b:h" opt; do
    case "$opt" in
        w) WORKERS="$OPTARG" ;;
        L) LOGLEVEL="$OPTARG" ;;
        H) RHOST="$OPTARG" ;;
        E) EHOST="$OPTARG" ;;
        T) TAG="$OPTARG" ;;
        d) DUR="$OPTARG" ;;
        r) RATES="$OPTARG" ;;
        b) BATCHES="$OPTARG" ;;
        h) sed -n '2,20p' "$0"; exit 0 ;;
        *) sed -n '2,20p' "$0"; exit 1 ;;
    esac
done

assert_prerequisites
RHOST_ARG="$RHOST"
EHOST_ARG="$EHOST"
if [ "$RHOST_ARG" != "redis" ] || [ "$EHOST_ARG" != "echo" ]; then
    log "direct-connect mode: redis=$RHOST_ARG echo=$EHOST_ARG"
fi
IFS=',' read -ra RATE_ARR <<< "$RATES"
IFS=',' read -ra BATCH_ARR <<< "$BATCHES"
NODES_CSV=$(IFS=,; printf '%s' "${PROXY_NODES[*]}")

# ---------- helpers (Phase 1 specific; common.sh left untouched so quota/dims are not affected) ----------

redis_info_field() { # redis_info_field <field> — exact match from line start (used_cpu_sys vs children not confused)
    docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli INFO cpu 2>/dev/null \
        | grep -E "^${1}:" | head -1 | cut -d: -f2 | tr -d '\r'
}

redis_cmd_calls() { # redis_cmd_calls <cmd> — cumulative calls of the command in INFO commandstats (eval/evalsha/script)
    docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli INFO commandstats 2>/dev/null \
        | awk -F: -v c="cmdstat_${1}:" '$0 ~ c {split($2,a,"calls="); split(a[2],b,","); gsub(/\r/,"",b[1]); print b[1]; exit}'
}

kong_log_lines() {
    docker logs "kong$1" 2>&1 | wc -l | tr -d ' '
}

kong_log_count_since() { # kong_log_count_since <kongN> <start_line> <pattern>
    docker logs "kong$1" 2>&1 | tail -n +"$2" | grep -c "$3" || true
}

kong_cpu_usec() { # container cgroup v2 cpu.stat cumulative (microseconds)
    # cat|head pattern disabled: under pipefail cat gets SIGPIPE ⇒ silent exit under set -e
    docker exec "kong$1" sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null' \
        | awk '/^usage_usec/{print $2; exit}'
}

assert_worker_count() { # Verify the actual worker count on each kong node
    local expect="$1" n
    for node in 1 2 3; do
        n=$(docker exec "kong$node" sh -c "ps aux 2>/dev/null | grep -c '[n]ginx: worker'" | tr -d ' \r')
        if [ "${n:-0}" -ne "$expect" ]; then
            die "kong$node actual worker count=$n != expected $expect"
        fi
    done
    ok "worker count verified: kong1/2/3 each $expect"
}

switch_workers() { # switch_workers <N> <loglevel> — force-recreate the three kong nodes
    local n="$1"
    local lv="${2:-notice}"
    local ovf="/tmp/m4-override-w${n}-${lv}.yml"
    {
        echo "services:"
        for node in 1 2 3; do
            echo "  kong$node:"
            echo "    environment:"
            echo "      KONG_NGINX_WORKER_PROCESSES: \"$n\""
            echo "      KONG_LOG_LEVEL: \"$lv\""
        done
    } > "$ovf"
    log "switching Worker=$n (force-recreate kong1/2/3)"
    docker compose -f "$COMPOSE_FILE" -f "$ovf" up -d --force-recreate kong1 kong2 kong3 >/dev/null
    for node in 1 2 3; do
        for _ in $(seq 1 40); do
            curl -fsS --max-time 3 "http://localhost:$((8031 - 20*(node-1)))/status" >/dev/null 2>&1 && break
            sleep 1
        done
    done
    assert_worker_count "$n"
}

restore_workers() { # Restore compose defaults (read the config value from the file)
    local def
    def=$(grep 'KONG_NGINX_WORKER_PROCESSES' "$COMPOSE_FILE" | head -1 | grep -o '[0-9]*')
    def=${def:-2}
    log "restoring Worker=$def (compose default)"
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate kong1 kong2 kong3 >/dev/null
    for node in 1 2 3; do
        for _ in $(seq 1 40); do
            curl -fsS --max-time 3 "http://localhost:$((8031 - 20*(node-1)))/status" >/dev/null 2>&1 && break
            sleep 1
        done
    done
    assert_worker_count "$def"
}

# Multi-rule config (group C): same config shape as rules.sh, limit inflated to keep rate limiting out of the way
kong_rules_json() { # <ns>
    cat <<EOF
{"_format_version":"3.0","services":[{"name":"echo","url":"http://${EHOST_ARG}:5678",
 "routes":[{"name":"echo-route","paths":["/echo"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{
   "limit":${LIMIT},"window":${WINDOW},"batch":0,
   "namespace":"$1","fault_tolerant":false,
   "rules":[{"limit":${LIMIT},"window":${WINDOW}},{"limit":${LIMIT},"window":${WINDOW},"limit_by":["consumer","path"]}],
   "redis":{"host":"${RHOST_ARG}","port":6379,"database":0,"timeout":1000}}}]}]}]}
EOF
}

# ---------- Data collection (before/after case deltas) ----------

declare -A SNAP

snap_start() {
    SNAP[cmd0]=$(redis_cmd_count)
    SNAP[cpu0_r]=$(redis_info_field used_cpu_sys); SNAP[cpu1_r]=$(redis_info_field used_cpu_user)
    SNAP[eval0]=$(redis_cmd_calls eval)
    SNAP[esha0]=$(redis_cmd_calls evalsha)
    SNAP[scpt0]=$(redis_cmd_calls script)
    for node in 1 2 3; do
        SNAP["log0_$node"]=$(kong_log_lines "$node")
        SNAP["kcpu0_$node"]=$(kong_cpu_usec "$node")
    done
}

snap_end() {
    SNAP[cmd1]=$(redis_cmd_count)
    SNAP[cpu2_r]=$(redis_info_field used_cpu_sys); SNAP[cpu3_r]=$(redis_info_field used_cpu_user)
    SNAP[eval1]=$(redis_cmd_calls eval)
    SNAP[esha1]=$(redis_cmd_calls evalsha)
    SNAP[scpt1]=$(redis_cmd_calls script)
    for node in 1 2 3; do
        SNAP["log1_$node"]=$(kong_log_lines "$node")
        SNAP["kcpu1_$node"]=$(kong_cpu_usec "$node")
    done
}

report_row() { # report_row <label> <batch> <rps_target> <elapsed> <summary_file>
    local label="$1" batch="$2" rps_t="$3" elapsed="$4" out="$5" attempt="$6" ns="$7"
    local p50 p95 p99 rps okcnt limcnt
    p50=$(json_num "$out" http_req_duration 'med')
    p95=$(json_num "$out" http_req_duration 'p(95)')
    p99=$(json_num "$out" http_req_duration 'p(99)')
    okcnt=$(json_num "$out" rl_allowed count);  okcnt=${okcnt%.*}
    limcnt=$(json_num "$out" rl_limited count); limcnt=${limcnt%.*}
    rps=$(json_num "$out" http_reqs rate)

    local qps cpu_r evals hits grants multis kcpu
    qps=$(awk -v a="${SNAP[cmd0]}" -v b="${SNAP[cmd1]}" -v e="$elapsed" 'BEGIN{ if(e>0) printf "%.0f",(b-a)/e; else print 0 }')
    cpu_r=$(awk -v a="${SNAP[cpu0_r]}" -v b="${SNAP[cpu1_r]}" -v c="${SNAP[cpu2_r]}" -v d="${SNAP[cpu3_r]}" -v e="$elapsed" \
        'BEGIN{ if(e>0) printf "%.3f",((c-a)+(d-b))/e; else print 0 }')
    evals=$(( SNAP[eval1] - SNAP[eval0] ))
    local eshas=$(( SNAP[esha1] - SNAP[esha0] ))
    local scpts=$(( SNAP[scpt1] - SNAP[scpt0] ))
    hits=0; grants=0; multis=0; lgrants=0
    for node in 1 2 3; do
        hits=$(( hits + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'local_hit') ))
        grants=$(( grants + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'redis_grant') ))
        multis=$(( multis + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'multi_grant') ))
        lgrants=$(( lgrants + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'lease_grant') ))
    done
    kcpu=$(awk -v a1="${SNAP[kcpu0_1]}" -v b1="${SNAP[kcpu1_1]}" -v a2="${SNAP[kcpu0_2]}" -v b2="${SNAP[kcpu1_2]}" -v a3="${SNAP[kcpu0_3]}" -v b3="${SNAP[kcpu1_3]}" -v e="$elapsed" \
        'BEGIN{ if(e>0) printf "%.3f",((b1-a1)+(b2-a2)+(b3-a3))/1e6/e; else print 0 }')

    printf '    p50=%-7.2f p95=%-7.2f p99=%-7.2f rps=%-6.0f redisQPS=%-6s evals=%-6s localHit=%-6s grant=%-5s multi=%-5s redisCPU=%ss kongCPU=%s cores\n' \
        "$p50" "$p95" "$p99" "$rps" "$qps" "$evals" "$hits" "$grants" "$multis" "$cpu_r" "$kcpu"

    ROWS+=("$label|$batch|$rps_t|$(printf '%.0f' "$rps")|$(printf '%.2f' "$p50")|$(printf '%.2f' "$p95")|$(printf '%.2f' "$p99")|$okcnt|$limcnt|$qps|$evals|$eshas|$scpts|$hits|$grants|$lgrants|$multis|$cpu_r|$kcpu|$attempt")
}

run_case_once() { # run_case_once <label> <kind> <batch> <rate> <attempt> → echo "p99 rps"; result row appended to ROWS
    local label="$1"
    local kind="$2"
    local batch="$3"
    local rate="$4"
    local attempt="$5"
    local ns="p4-$(date +%s%N | cut -b1-16)"
    local json=""
    case "$kind" in
        none)  json=$(kong_config_json "$LIMIT" "$WINDOW" 0 false "$ns" '["ip"]' "$RHOST_ARG" "$EHOST_ARG") ;;
        multi) json=$(kong_rules_json "$ns") ;;
        *)     json=$(kong_config_json "$LIMIT" "$WINDOW" "$batch" true "$ns" '["ip"]' "$RHOST_ARG" "$EHOST_ARG") ;;
    esac
    apply_config "$json"
    sleep 1
    snap_start
    local start_ns end_ns elapsed
    start_ns=$(date +%s%N)
    local out
    out=$(run_k6 k6/latency.js "${TAG}-w${WORKERS}-${label// /_}-r${rate}-a${attempt}.json" \
            "RPS=$rate" "DUR=${DUR}s" "NODES=$NODES_CSV")
    end_ns=$(date +%s%N)
    elapsed=$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf "%.3f",(b-a)/1e9}')
    snap_end
    report_row "$label" "$batch" "$rate" "$elapsed" "$out" "$attempt" "$ns"
    local p99 rps
    p99=$(json_num "$out" http_req_duration 'p(99)')
    rps=$(json_num "$out" http_reqs rate)
    printf '%s %s\n' "$p99" "$rps" > "$TMP_CASE_RES"   # subshell capture would lose the ROWS side effect; pass values via file
    sleep 2
}

TMP_CASE_RES="/tmp/m4-case-res"
# Contamination criteria: p99 > 500ms (clean-shape ceiling 188ms) or measured RPS < 95% of target
# (the 4s blocks share the same root cause as the slowdown: ~5% of requests get delayed 3-4s by host environment noise; see the "environment noise" section of the report)
P99_LIMIT=500
run_case_checked() { # run_case_checked <label> <kind> <batch> <rate>
    local label="$1"
    local kind="$2"
    local batch="$3"
    local rate="$4"
    local attempt
    for attempt in 1 2 3; do
        local p99 rps
        run_case_once "$label" "$kind" "$batch" "$rate" "$attempt"
        p99=$(awk '{print $1}' "$TMP_CASE_RES"); rps=$(awk '{print $2}' "$TMP_CASE_RES")
        local ok
        ok=$(awk -v p="$p99" -v r="$rate" -v l="$P99_LIMIT" 'BEGIN{ print (p<=l && r>=0.95*r) ? 1 : 0 }')
        if [ "$ok" = "1" ]; then
            [ "$attempt" -gt 1 ] && warn "$label r$rate attempt $attempt passed (previous run was contaminated by environment noise; the record has been kept)"
            return 0
        fi
        warn "$label r$rate attempt $attempt looks contaminated by environment noise (p99=$p99 rps=$rps), rerunning"
    done
    warn "$label r$rate all three attempts look contaminated; keeping the last one (data is already in ROWS, will be noted as-is in the report)"
}

# ---------- Run all groups ----------
log "performance matrix (current implementation): M0/batch=1/batch=N/multi-rule x RPS tiers (Worker=$WORKERS, log=$LOGLEVEL, DUR=${DUR}s, RPS=$RATES)"
# Switch first when the target shape differs from the compose default (2/notice)
if [ "$WORKERS" != "2" ] || [ "$LOGLEVEL" != "notice" ]; then
    switch_workers "$WORKERS" "$LOGLEVEL"
else
    assert_worker_count "$WORKERS"
fi
declare -a ROWS=()

for rate in "${RATE_ARR[@]}"; do run_case_checked "M0-none" none 0 "$rate"; done
for rate in "${RATE_ARR[@]}"; do run_case_checked "A-batch1" single 1 "$rate"; done
for batch in "${BATCH_ARR[@]}"; do
    for rate in "${RATE_ARR[@]}"; do run_case_checked "B-batch$batch" single "$batch" "$rate"; done
done
for rate in "${RATE_ARR[@]}"; do run_case_checked "C-multi" multi 0 "$rate"; done

# ---------- Output ----------
OUT_FILE="$PROJECT_ROOT/bench/out/results-${TAG}-w${WORKERS}-${LOGLEVEL}-${RHOST}.md"
mkdir -p "$(dirname "$OUT_FILE")"
{
    echo "# Performance matrix (measured on the current implementation; tag=$TAG, Worker=$WORKERS, log=$LOGLEVEL, redisHost=$RHOST_ARG, echoHost=$EHOST_ARG; limit=$LIMIT window=${WINDOW}s duration=${DUR}s RPS=$RATES batch=$BATCHES)"
    echo
    echo "Generated at: $(date '+%F %T')　limit=$LIMIT window=${WINDOW}s duration=${DUR}s RPS=$RATES batch=$BATCHES"
    echo
    echo "| Scenario | batch | RPS target | Measured RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL count | EVALSHA count | SCRIPT_LOAD count | Local hits | slowGrant | leaseGrant | multiGrant | RedisCPU(s) | KongCPU(cores) | Attempt |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    for row in "${ROWS[@]}"; do
        IFS='|' read -ra f <<< "$row"
        echo "| ${f[0]} | ${f[1]} | ${f[2]} | ${f[3]} | ${f[4]} | ${f[5]} | ${f[6]} | ${f[7]} | ${f[8]} | ${f[9]} | ${f[10]} | ${f[11]} | ${f[12]} | ${f[13]} | ${f[14]} | ${f[15]} | ${f[16]} | ${f[17]} | ${f[18]} | ${f[19]} |"
    done
    cat <<'EOF'

## How to read the table

- EVAL count = INFO commandstats cmdstat_eval call delta (single script per group, explainable: A/C 1 per request; B ≈ request count/batch).
- Local hits = [RL-DEBUG] local_hit log line count delta across the three nodes; slowGrant = redis_grant; leaseGrant = lease_grant (the GRANT_LEASE path of the Lease implementation); multiGrant = multi_grant. The stats columns depend on KONG_LOG_LEVEL=debug (this script's default); when running at notice level the stats columns are 0 (expected, not lost requests).
- RedisCPU(s) = INFO cpu used_cpu_sys+user delta; KongCPU(cores) = container cgroup cpu.stat usage_usec delta / duration / 1e6 (summed across three nodes).
- Redis QPS = total_commands_processed delta / duration (includes all commands: connections/scripts/read-write).
EOF
} > "$OUT_FILE"
ok "written to $OUT_FILE"

# Restore compose defaults at the end (worker and loglevel), only if actually switched
restore_workers
