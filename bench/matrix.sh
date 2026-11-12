#!/usr/bin/env bash
# ============================================================
# matrix.sh —— Phase 4 第一组性能基线（Legacy EVAL + Shared Inventory）
#
# 用法：
#   ./bench/matrix.sh -w 2      # Worker=2 全组（当前 compose 配置）
#   ./bench/matrix.sh -w 1      # 切 Worker=1 跑全组，结束恢复 compose 默认
#
# 组划分（不再全维度交叉）：
#   M0  无插件对照
#   A   单规则 batch=1（每请求 1 次 Redis EVAL）
#   B   单规则 batch>1（显式 batch=10/50/100；本地命中 + slow path EVAL）
#   C   多规则 GRANT_MULTI（每请求 1 次 EVAL）
#   RPS 档位：低 100 / 中 500 / 高 1000
#
# 路径核实（不允许仅凭配置推测）：
#   Redis EVAL 次数      → INFO commandstats cmdstat_eval calls 差值
#   本地库存命中         → Kong 日志 [RL-DEBUG] local_hit 行数差值
#   Redis 库存领取次数   → Kong 日志 [RL-DEBUG] redis_grant 行数差值
#   多规则 EVAL          → Kong 日志 [RL-DEBUG] multi_grant 行数差值
#   Redis QPS/CPU        → INFO total_commands_processed / INFO cpu 差值
#   Kong CPU             → 容器 cgroup cpu.stat usage_usec 差值
# ============================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

WORKERS="${WORKERS:-2}"      # 目标 Worker 数（-w 覆盖）
LOGLEVEL="${LOGLEVEL:-notice}" # KONG_LOG_LEVEL（-L 覆盖；error 组用于隔离调试日志背压因素）
RHOST="redis"                  # Redis host（-H ip 切换 IP 直连，绕开容器 DNS 间歇阻塞——Phase 0 发现的现有缺陷）
EHOST="echo"                   # 上游 echo host（-E ip 切换 IP 直连；容器 DNS 缺陷影响 proxy 链路）
DUR="${DUR:-20}"             # 每组时长（秒）
RATES="${RATES:-100,500,1000}"
BATCHES="${BATCHES:-10,50,100}"
LIMIT=1000000                # 故意放大，隔离限流路径（只测放行）
WINDOW=60

while getopts "w:L:HE:d:r:b:h" opt; do
    case "$opt" in
        w) WORKERS="$OPTARG" ;;
        L) LOGLEVEL="$OPTARG" ;;
        H) RHOST="ip" ;;
        d) DUR="$OPTARG" ;;
        r) RATES="$OPTARG" ;;
        b) BATCHES="$OPTARG" ;;
        h) sed -n '2,20p' "$0"; exit 0 ;;
        *) sed -n '2,20p' "$0"; exit 1 ;;
    esac
done

assert_prerequisites
RHOST_ARG="$RHOST"
if [ "$RHOST" = "ip" ]; then
    RHOST_ARG=$(docker inspect kong-ratelimit-redis-1 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    log "Redis IP 直连：$RHOST_ARG"
fi
EHOST_ARG="$EHOST"
if [ "$EHOST" = "ip" ]; then
    EHOST_ARG=$(docker inspect kong-ratelimit-echo-1 -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
    log "echo 上游 IP 直连：$EHOST_ARG"
fi
IFS=',' read -ra RATE_ARR <<< "$RATES"
IFS=',' read -ra BATCH_ARR <<< "$BATCHES"
NODES_CSV=$(IFS=,; printf '%s' "${PROXY_NODES[*]}")

# ---------- helpers（Phase 1 专用，不改 common.sh 以免影响 quota/dims）----------

redis_info_field() { # redis_info_field <field> —— 行首精确匹配（used_cpu_sys 与 children 不混淆）
    docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli INFO cpu 2>/dev/null \
        | grep -E "^${1}:" | head -1 | cut -d: -f2 | tr -d '\r'
}

redis_eval_calls() { # 当前 cmdstat_eval 累计调用次数（截断逗号后的 usec 段）
    docker compose -f "$COMPOSE_FILE" exec -T redis redis-cli INFO commandstats 2>/dev/null \
        | awk -F: '/cmdstat_eval:/{split($2,a,"calls="); split(a[2],b,","); gsub(/\r/,"",b[1]); print b[1]; exit}'
}

kong_log_lines() {
    docker logs "kong$1" 2>&1 | wc -l | tr -d ' '
}

kong_log_count_since() { # kong_log_count_since <kongN> <start_line> <pattern>
    docker logs "kong$1" 2>&1 | tail -n +"$2" | grep -c "$3" || true
}

kong_cpu_usec() { # 容器 cgroup v2 cpu.stat 累计（微秒）
    docker exec "kong$1" sh -c 'cat /sys/fs/cgroup/cpu.stat 2>/dev/null | head -1' \
        | awk '{print $2}'
}

assert_worker_count() { # 校验每个 kong 节点实际 worker 数
    local expect="$1" n
    for node in 1 2 3; do
        n=$(docker exec "kong$node" sh -c "ps aux 2>/dev/null | grep -c '[n]ginx: worker'" | tr -d ' \r')
        if [ "${n:-0}" -ne "$expect" ]; then
            die "kong$node 实际 worker 数=$n ≠ 期望 $expect"
        fi
    done
    ok "worker 数校验通过：kong1/2/3 各 $expect"
}

switch_workers() { # switch_workers <N> <loglevel> —— force-recreate 三个 kong 节点
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
    log "切换 Worker=$n（force-recreate kong1/2/3）"
    docker compose -f "$COMPOSE_FILE" -f "$ovf" up -d --force-recreate kong1 kong2 kong3 >/dev/null
    for node in 1 2 3; do
        for _ in $(seq 1 40); do
            curl -fsS --max-time 3 "http://localhost:$((8031 - 20*(node-1)))/status" >/dev/null 2>&1 && break
            sleep 1
        done
    done
    assert_worker_count "$n"
}

restore_workers() { # 恢复 compose 默认（读文件内配置值）
    local def
    def=$(grep 'KONG_NGINX_WORKER_PROCESSES' "$COMPOSE_FILE" | head -1 | grep -o '[0-9]*')
    def=${def:-2}
    log "恢复 Worker=$def（compose 默认）"
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate kong1 kong2 kong3 >/dev/null
    for node in 1 2 3; do
        for _ in $(seq 1 40); do
            curl -fsS --max-time 3 "http://localhost:$((8031 - 20*(node-1)))/status" >/dev/null 2>&1 && break
            sleep 1
        done
    done
    assert_worker_count "$def"
}

# 多规则配置（组 C）：沿用 rules.sh 的配置形状，limit 放大避免限流介入
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

# ---------- 数据采集（case 前后差值）----------

declare -A SNAP

snap_start() {
    SNAP[cmd0]=$(redis_cmd_count)
    SNAP[cpu0_r]=$(redis_info_field used_cpu_sys); SNAP[cpu1_r]=$(redis_info_field used_cpu_user)
    SNAP[eval0]=$(redis_eval_calls)
    for node in 1 2 3; do
        SNAP["log0_$node"]=$(kong_log_lines "$node")
        SNAP["kcpu0_$node"]=$(kong_cpu_usec "$node")
    done
}

snap_end() {
    SNAP[cmd1]=$(redis_cmd_count)
    SNAP[cpu2_r]=$(redis_info_field used_cpu_sys); SNAP[cpu3_r]=$(redis_info_field used_cpu_user)
    SNAP[eval1]=$(redis_eval_calls)
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
    hits=0; grants=0; multis=0
    for node in 1 2 3; do
        hits=$(( hits + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'local_hit') ))
        grants=$(( grants + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'redis_grant') ))
        multis=$(( multis + $(kong_log_count_since "$node" "${SNAP[log0_$node]}" 'multi_grant') ))
    done
    kcpu=$(awk -v a1="${SNAP[kcpu0_1]}" -v b1="${SNAP[kcpu1_1]}" -v a2="${SNAP[kcpu0_2]}" -v b2="${SNAP[kcpu1_2]}" -v a3="${SNAP[kcpu0_3]}" -v b3="${SNAP[kcpu1_3]}" -v e="$elapsed" \
        'BEGIN{ if(e>0) printf "%.3f",((b1-a1)+(b2-a2)+(b3-a3))/1e6/e; else print 0 }')

    printf '    p50=%-7.2f p95=%-7.2f p99=%-7.2f rps=%-6.0f redisQPS=%-6s evals=%-6s localHit=%-6s grant=%-5s multi=%-5s redisCPU=%ss kongCPU=%s核\n' \
        "$p50" "$p95" "$p99" "$rps" "$qps" "$evals" "$hits" "$grants" "$multis" "$cpu_r" "$kcpu"

    ROWS+=("$label|$batch|$rps_t|$(printf '%.0f' "$rps")|$(printf '%.2f' "$p50")|$(printf '%.2f' "$p95")|$(printf '%.2f' "$p99")|$okcnt|$limcnt|$qps|$evals|$hits|$grants|$multis|$cpu_r|$kcpu|$attempt")
}

run_case_once() { # run_case_once <label> <kind> <batch> <rate> <attempt> → echo "p99 rps"；结果行写入 ROWS
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
    out=$(run_k6 k6/latency.js "p1-w${WORKERS}-${label// /_}-r${rate}-a${attempt}.json" \
            "RPS=$rate" "DUR=${DUR}s" "NODES=$NODES_CSV")
    end_ns=$(date +%s%N)
    elapsed=$(awk -v a="$start_ns" -v b="$end_ns" 'BEGIN{printf "%.3f",(b-a)/1e9}')
    snap_end
    report_row "$label" "$batch" "$rate" "$elapsed" "$out" "$attempt" "$ns"
    local p99 rps
    p99=$(json_num "$out" http_req_duration 'p(99)')
    rps=$(json_num "$out" http_reqs rate)
    printf '%s %s\n' "$p99" "$rps" > "$TMP_CASE_RES"   # 子 shell 捕获会丢 ROWS 副作用，改文件传值
    sleep 2
}

TMP_CASE_RES="/tmp/m4-case-res"
# 污染判据：p99 > 500ms（干净形态上限 188ms）或实测 RPS < 目标 95%
# （4s 块与掉速同源：~5% 请求被宿主机环境噪声推迟 3-4s；详见报告"环境噪声"节）
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
            [ "$attempt" -gt 1 ] && warn "$label r$rate 第 $attempt 次尝试通过（前次被环境噪声污染，已保留记录）"
            return 0
        fi
        warn "$label r$rate 第 $attempt 次尝试疑似环境噪声污染（p99=$p99 rps=$rps），重跑"
    done
    warn "$label r$rate 三次尝试均疑似污染，采用最后一次（数据已在 ROWS，报告中如实标注）"
}

# ---------- 执行全部组 ----------
log "Phase 4 第一组基线：Legacy EVAL + Shared Inventory（Worker=$WORKERS, log=$LOGLEVEL, DUR=${DUR}s, RPS=$RATES）"
# 目标形态与 compose 默认（2/notice）不同时先切换
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

# ---------- 输出 ----------
OUT_FILE="$PROJECT_ROOT/bench/out/results-p1-w${WORKERS}-${LOGLEVEL}-${RHOST}.md"
mkdir -p "$(dirname "$OUT_FILE")"
{
    echo "# Phase 4 第一组基线 —— Legacy EVAL + Shared Inventory（Worker=$WORKERS, log=$LOGLEVEL, redisHost=$RHOST_ARG）"
    echo
    echo "生成时间：$(date '+%F %T')　limit=$LIMIT window=${WINDOW}s 时长=${DUR}s RPS=$RATES batch=$BATCHES"
    echo
    echo "| 场景 | batch | RPS目标 | 实测RPS | p50 | p95 | p99 | 200 | 429 | RedisQPS | EVAL次数 | 本地命中 | slowGrant | multiGrant | RedisCPU(s) | KongCPU(核) | 尝试 |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
    for row in "${ROWS[@]}"; do
        IFS='|' read -ra f <<< "$row"
        echo "| ${f[0]} | ${f[1]} | ${f[2]} | ${f[3]} | ${f[4]} | ${f[5]} | ${f[6]} | ${f[7]} | ${f[8]} | ${f[9]} | ${f[10]} | ${f[11]} | ${f[12]} | ${f[13]} | ${f[14]} | ${f[15]} | ${f[16]} |"
    done
    cat <<'EOF'

## 读表口径

- EVAL次数 = INFO commandstats cmdstat_eval 调用差值（组内单一脚本，可解释：A/C 每请求 1 次；B ≈ 请求数/batch）。
- 本地命中 = 三节点 [RL-DEBUG] local_hit 日志行数差值；slowGrant = redis_grant；multiGrant = multi_grant。
- RedisCPU(s) = INFO cpu used_cpu_sys+user 差值；KongCPU(核) = 容器 cgroup cpu.stat usage_usec 差值/时长/1e6（三节点合计）。
- Redis QPS = total_commands_processed 差值/时长（含连接/脚本/读写全量命令）。
EOF
} > "$OUT_FILE"
ok "已写入 $OUT_FILE"

# 结束恢复 compose 默认（worker 与 loglevel），仅当实际切换过
restore_workers
