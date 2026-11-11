#!/usr/bin/env bash
# ============================================================
# 公共函数：配置下发、Redis 计量、k6 调用
# 由 quota.sh / matrix.sh source 使用
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
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

assert_prerequisites() {
    require_cmd docker
    require_cmd k6
    require_cmd curl
    require_cmd python3

    docker compose version >/dev/null 2>&1 \
        || die "需要 docker compose v2（docker-compose-plugin），当前不可用"

    curl -fsS --max-time 3 "${ADMIN_NODES[0]}/status" >/dev/null 2>&1 \
        || die "kong1 管理面不可达，请先执行：docker compose up -d"
}

# 生成 Kong DB-less 声明式配置（JSON）
# 用法：kong_config_json <limit> <window> <batch> <with_plugin>
kong_config_json() {
    local limit="$1" window="$2" batch="$3" with_plugin="${4:-true}"
    local plugins=""

    if [ "$with_plugin" = "true" ]; then
        plugins=$(cat <<EOF
[{"name":"rate-limit-advanced","config":{
  "limit":${limit},"window":${window},"batch":${batch},
  "limit_by":["ip"],"namespace":"rl","fault_tolerant":true,
  "redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]
EOF
)
    else
        plugins="[]"
    fi

    cat <<EOF
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"echo-route","paths":["/echo"],"strip_path":false,
 "plugins":${plugins}}]}]}
EOF
}

apply_config() {
    local json="$1" admin
    # DB-less 模式下每个节点各持一份配置，必须逐个下发
    for admin in "${ADMIN_NODES[@]}"; do
        if ! curl -fsS --max-time 10 -X POST "$admin/config" \
                -H 'Content-Type: application/json' -d "$json" >/dev/null; then
            warn "下发配置到 $admin 失败（该节点可能仍在用旧配置）"
        fi
    done
}

redis_cmd_count() {
    docker compose -f "$COMPOSE_FILE" exec -T redis \
        redis-cli INFO stats 2>/dev/null \
        | awk -F: '/^total_commands_processed:/{gsub(/[ \r]/,"",$2); print $2; exit}'
}

# 读 k6 summary JSON：json_num <file> <metric> <field>
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

# 跑 k6，成功则把产物路径打到 stdout（k6 自身输出走 stderr）
# 用法：run_k6 <script> <out-name> [KEY=VALUE ...]
run_k6() {
    local script="$1" outname="$2"; shift 2
    local outdir="$PROJECT_ROOT/bench/out"
    mkdir -p "$outdir"
    local out="$outdir/$outname"
    rm -f "$out"

    local envargs=()
    local kv
    for kv in "$@"; do envargs+=(-e "$kv"); done

    ( cd "$PROJECT_ROOT" && k6 run --quiet "${envargs[@]}" -e "OUT=$out" "$script" >&2 ) \
        || die "k6 执行失败"

    [ -f "$out" ] || die "k6 没有产出 $out"
    printf '%s\n' "$out"
}
