#!/usr/bin/env bash
# E1/E2：配额正确性 —— 三个节点共用一个池子
#
#   ./quota.sh -l 100 -b 1  -p 150   # 期望恰好 100 通过
#   ./quota.sh -l 100 -b 20 -p 150   # 期望落在 [40, 100]
#
# window 默认 3600，是为了让"补充"在几十秒内可忽略，
# 否则每秒补几个令牌，结果就不是整数了。

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
选项：
  -l  limit      每窗口配额（默认 100）
  -b  batch      每次向 Redis 领取的令牌数，0=auto（默认 1）
  -w  window     窗口秒数（默认 3600）
  -p  per_node   每个节点打多少次（默认 150）
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

# P0-6：每轮独立 namespace，杜绝上一轮残留状态污染本轮结果
NS="rl-$(date +%s)-$$"
log "下发配置：limit=$LIMIT window=$WINDOW batch=$BATCH namespace=$NS"
apply_config "$(kong_config_json "$LIMIT" "$WINDOW" "$BATCH" true "$NS")"
sleep 2

log "打流量：${NODE_COUNT} 节点 × ${PER_NODE} = ${TOTAL} 次"
NODES_CSV=$(IFS=,; printf '%s' "${PROXY_NODES[*]}")
OUT=$(run_k6 k6/quota.js "quota-b${BATCH}.json" \
        "NODES=$NODES_CSV" "ITER=$TOTAL" "VUS=30")

ALLOWED=$(json_num "$OUT" rl_allowed count); ALLOWED=${ALLOWED%.*}
LIMITED=$(json_num "$OUT" rl_limited count); LIMITED=${LIMITED%.*}
OTHER=$(json_num "$OUT" rl_other count);     OTHER=${OTHER%.*}

# P0-5 运行时断言：每节点请求数必须严格等于 PER_NODE
assert_per_node_counts "$OUT" "$PER_NODE"

echo
echo "结果：allowed=$ALLOWED  limited=$LIMITED  other=$OTHER  total=$TOTAL"

if [ "$OTHER" -gt 0 ]; then
    warn "出现非 200/429 响应（$OTHER 个），先看日志：docker compose logs kong1"
fi

if [ "$BATCH" -le 1 ]; then
    if [ "$ALLOWED" -eq "$LIMIT" ]; then
        ok "PASS：严格等于配额 $LIMIT（全局一致）"
    else
        printf '\033[31mFAIL：期望 %s，实际 %s\033[0m\n' "$LIMIT" "$ALLOWED"
        cat <<'EOF'
排查顺序：
  1) 三个节点是否都收到了配置（看上面有没有"下发失败"的警告）
  2) 各节点写的是不是同一个 Redis key（redis-cli KEYS 'kong:rl:*'）
  3) 是不是 window 太小导致期间补充了令牌（用 -w 3600）
EOF
        exit 1
    fi
else
    LOWER=$(( LIMIT - NODE_COUNT * BATCH ))
    [ "$LOWER" -lt 0 ] && LOWER=0

    if [ "$ALLOWED" -gt "$LIMIT" ]; then
        printf '\033[31mFAIL：超发了！allowed=%s > limit=%s\033[0m\n' "$ALLOWED" "$LIMIT"
        cat <<'EOF'
这不该发生。可能原因：
  - Lua 脚本被改动
  - 库存跨窗口未过期（检查 store.fill 的 TTL）
  - limit 实际没生效（配置没下发成功）
EOF
        exit 1
    elif [ "$ALLOWED" -ge "$LOWER" ]; then
        PCT=$(awk -v a="$ALLOWED" -v l="$LIMIT" 'BEGIN{printf "%.1f", a*100/l}')
        ok "PASS：落在 [$LOWER, $LIMIT] 内，利用率 ${PCT}%（少发 $(( LIMIT - ALLOWED )) 个）"
    else
        printf '\033[33m低于理论下界：allowed=%s < %s\033[0m\n' "$ALLOWED" "$LOWER"
        cat <<'EOF'
说明有额外滞留，最常见的原因：
  - lua_shared_dict 没生效，降级成"每个 worker 一份库存"（worker 数 × batch 都被滞留）
  - 检查 docker compose logs kong1 | grep -i shared
EOF
    fi
fi
