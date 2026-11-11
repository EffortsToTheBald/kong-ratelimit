#!/usr/bin/env bash
# E3/E4：batch × RPS 矩阵，输出 bench/results.md
#
#   ./matrix.sh                          # 默认 200/1000 RPS × batch 0,1,5,20
#   ./matrix.sh -r 200,1000,3000 -d 60
#
# 注意：limit 故意设得很大（默认 1000000），让限流不介入，
# 否则测到的是 429 路径而不是放行路径。这一条必须写进设计文档。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

BATCHES="0,1,5,20"
RATES="200,1000"
DURATION=30
LIMIT=1000000
WINDOW=60

usage() {
    sed -n '2,7p' "$0"
    cat <<'EOF'
选项：
  -b  batches      逗号分隔，0 表示 auto（默认 0,1,5,20）
  -r  rates        逗号分隔的 RPS（默认 200,1000）
  -d  duration     每组秒数（默认 30）
  -l  limit        限流配额，默认 1000000（故意放大以隔离限流路径）
  -w  window       窗口秒数（默认 60）
EOF
}

while getopts "b:r:d:l:w:h" opt; do
    case "$opt" in
        b) BATCHES="$OPTARG" ;;
        r) RATES="$OPTARG" ;;
        d) DURATION="$OPTARG" ;;
        l) LIMIT="$OPTARG" ;;
        w) WINDOW="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

assert_prerequisites

IFS=',' read -ra BATCH_ARR <<< "$BATCHES"
IFS=',' read -ra RATE_ARR  <<< "$RATES"
NODES_CSV=$(IFS=,; printf '%s' "${PROXY_NODES[*]}")
DUR="${DURATION}s"

ROWS=()

add_row() { # label batch rate p50 p95 p99 ok limited rps redis_ops
    ROWS+=("| $1 | $2 | $3 | $9 | $4 | $5 | $6 | $7 | $8 | $10 |")
}

# 跑一组；参数：label batch rate
run_case() {
    local label="$1" batch="$2" rate="$3"

    local json summary out
    # 每个用例独立 namespace：桶状态不跨用例残留，Redis ops 统计才可比（P0-6）
    local ns="rl-$(date +%s%N | cut -b1-16)-b${batch}"
    if [ "$label" = "M0 基线" ]; then
        json=$(kong_config_json "$LIMIT" "$WINDOW" 0 false "$ns")
    else
        json=$(kong_config_json "$LIMIT" "$WINDOW" "$batch" true "$ns")
    fi

    apply_config "$json"
    sleep 1

    local before_cmds=0 after_cmds=0 start_ns end_ns elapsed
    if [ "$label" != "M0 基线" ]; then
        before_cmds=$(redis_cmd_count)
    fi
    start_ns=$(date +%s%N)

    out=$(run_k6 k6/latency.js "b${batch}-r${rate}.json" \
            "RPS=$rate" "DUR=$DUR" "NODES=$NODES_CSV")

    end_ns=$(date +%s%N)
    elapsed=$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf "%.3f",(b-a)/1e9}')

    local ops=0
    if [ "$label" != "M0 基线" ]; then
        after_cmds=$(redis_cmd_count)
        ops=$(awk -v a="$before_cmds" -v b="$after_cmds" -v e="$elapsed" \
              'BEGIN{ if (e>0) printf "%.0f",(b-a)/e; else print 0 }')
    fi

    local p50 p95 p99 okcnt limcnt rps
    p50=$(json_num "$out" http_req_duration 'med')
    p95=$(json_num "$out" http_req_duration 'p(95)')
    p99=$(json_num "$out" http_req_duration 'p(99)')
    okcnt=$(json_num "$out" rl_allowed count);  okcnt=${okcnt%.*}
    limcnt=$(json_num "$out" rl_limited count); limcnt=${limcnt%.*}
    rps=$(json_num "$out" http_reqs rate)

    printf '    p50=%-7.2f p95=%-7.2f p99=%-7.2f rps=%-6.0f redis=%s/s\n' \
        "$p50" "$p95" "$p99" "$rps" "$ops"

    ROWS+=("| $label | $batch | $rate | $(printf '%.0f' "$rps") | $(printf '%.2f' "$p50") | $(printf '%.2f' "$p95") | $(printf '%.2f' "$p99") | $okcnt | $limcnt | $ops |")
}

# ---------- M0 基线：不装插件 ----------
for rate in "${RATE_ARR[@]}"; do
    log "基线（无插件） RPS=$rate"
    run_case "M0 基线" "-" "$rate"
done

# ---------- M1..M4：不同 batch ----------
for batch in "${BATCH_ARR[@]}"; do
    for rate in "${RATE_ARR[@]}"; do
        log "batch=$batch RPS=$rate"
        if [ "$batch" = "0" ]; then
            label="M4 auto"
        else
            label="M-${batch}"
        fi
        run_case "$label" "$batch" "$rate"
    done
done

# ---------- 输出 ----------
OUT_FILE="$PROJECT_ROOT/bench/results.md"
{
    echo "# 实验结果"
    echo
    echo "生成时间：$(date '+%Y-%m-%d %H:%M:%S')　limit=$LIMIT / window=${WINDOW}s / 时长 ${DUR}"
    echo
    echo "| 场景 | batch | RPS 目标 | 实测 RPS | p50(ms) | p95(ms) | p99(ms) | 通过 | 429 | Redis ops/s |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    for row in "${ROWS[@]}"; do echo "$row"; done
    cat <<'EOF'

## 怎么读这张表

1. **p99 随 batch 单调下降**：batch 越大，slow path 命中率越低（≈1/batch）。
2. **Redis ops/s ≈ 实测 RPS / batch**：若明显偏离，说明有额外命令（连接、SELECT、脚本未命中缓存）。
3. **通过数在有配额时才会下降**：本表 limit 极大，所以通过数应≈总请求数；这证明测的是放行路径。
4. 如果 batch=1 与 batch=20 的 p99 差别很小，**不要藏**——说明本机 RTT 太小，
   跨机房 RTT 1ms 时收益才会显著。这条写进文档反而是加分项。
EOF
} > "$OUT_FILE"

echo
ok "已写入 $OUT_FILE"
