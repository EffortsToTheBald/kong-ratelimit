#!/usr/bin/env bash
# E6：多维限流全维度验证（Phase 2 · 多维 ADDED 需求）
#
# 用法：./bench/dims.sh
#
# 说明：
#   - 每场景独立 namespace + FLUSHDB；全部 batch=1（短路本地库存，杜绝残留干扰）
#   - consumer 场景自带 key-auth + 双 consumer + anonymous 的完整声明式配置（不改 kong.yml）
#   - 结束后最后一轮配置保留在运行时（后续 quota.sh/matrix.sh 会整体覆盖，无持久影响）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

PASS=0
FAIL=0
report() { # report <true|false> <说明>
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
code() { # code <url> [curl 参数...]
    local url="$1"; shift
    curl -s -o /dev/null -w '%{http_code}' "$@" "$url"
}
seq_eq() { # seq_eq "<期望串如 200200429>" "<实际串>"
    [ "$2" = "$1" ]
}
dexec() { # redis 容器内命令统一入口
    docker compose exec -T redis "$@"
}

echo "===== 场景 1/7: [ip, path] 两路径独立计数 ====="
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
echo "状态码序列: $R (期望 200200200200429429)"
report "$(seq_eq "200200200200429429" "$R" && echo true || echo false)" "[ip,path] 两路径各有独立配额"

echo "===== 场景 2/7: [method] GET/POST 分桶 ====="
NS="dims-method"
apply_config "$(kong_config_json 1 3600 1 true "$NS" '["method"]')" >/dev/null
sleep 2; fresh
R=""
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo -X POST)"
R+="$(code http://localhost:8030/echo)"
R+="$(code http://localhost:8030/echo -X POST)"
echo "状态码序列: $R (期望 200200429429)"
report "$(seq_eq "200200429429" "$R" && echo true || echo false)" "[method] GET/POST 各自独立配额"

echo "===== 场景 3/7: [header] 双租户 + 缺失哨兵 ====="
NS="dims-header"
# header 维度需要 header_name（entity_check 会拒绝缺失它的配置）——用 python 构造完整配置
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
echo "状态码序列: $R (期望 200200429429200429)"
report "$(seq_eq "200200429429200429" "$R" && echo true || echo false)" "[header] 不同头值分桶、缺失值独立哨兵桶"

echo "===== 场景 4/7: [route] key 含 route.id ====="
NS="dims-route"
apply_config "$(kong_config_json 1 3600 1 true "$NS" '["route"]')" >/dev/null
sleep 2; fresh
R="R1=$(code http://localhost:8030/echo) R2=$(code http://localhost:8030/echo)"
echo "$R (期望 R1=200 R2=429)"
KEYS=$(dexec redis-cli KEYS "kong:rl:*$NS*")
echo "keys: $KEYS"
route_ok=$(echo "$KEYS" | grep -qE 'route=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' && echo true || echo false)
seq_ok=$(seq_eq "R1=200 R2=429" "$R" && echo true || echo false)
report "$([ "$route_ok" = "true" ] && [ "$seq_ok" = "true" ] && echo true || echo false)" "[route] key 含 route UUID 且按 route 计数"

echo "===== 场景 5/7: [service] key 含 service.id ====="
NS="dims-service"
apply_config "$(kong_config_json 1 3600 1 true "$NS" '["service"]')" >/dev/null
sleep 2; fresh
R="S1=$(code http://localhost:8030/echo) S2=$(code http://localhost:8030/echo)"
echo "$R (期望 S1=200 S2=429)"
KEYS=$(dexec redis-cli KEYS "kong:rl:*$NS*")
echo "keys: $KEYS"
svc_ok=$(echo "$KEYS" | grep -qE 'service=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' && echo true || echo false)
seq_ok=$(seq_eq "S1=200 S2=429" "$R" && echo true || echo false)
report "$([ "$svc_ok" = "true" ] && [ "$seq_ok" = "true" ] && echo true || echo false)" "[service] key 含 service UUID 且按 service 计数"

echo "===== 场景 6/7: [consumer] key-auth 双 consumer + anonymous ====="
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
echo "状态码序列: $R (期望 200429200429200429)"
report "$(seq_eq "200429200429200429" "$R" && echo true || echo false)" "[consumer] alice/bob/anon 各自独立配额"
ERRS=$(docker compose logs kong1 --since 3m 2>/dev/null | grep -c "attempt to call" || true)
report "$([ "$ERRS" = "0" ] && echo true || echo false)" "consumer 场景无 Lua 调用异常（attempt to call=$ERRS，key-auth 先于限流执行）"

echo "===== 场景 7/7: 维度顺序 ⇒ 不同指纹 ====="
F1=$(docker compose exec -T kong1 resty -e '
local a = require "kong.plugins.rate-limit-advanced.lib.algorithm"
io.write(a.policy_fingerprint{limit=100, window=3600, burst=0, batch=1, limit_by={"ip","path"}, namespace="x", redis={key_prefix="kong:rl"}})
')
F2=$(docker compose exec -T kong1 resty -e '
local a = require "kong.plugins.rate-limit-advanced.lib.algorithm"
io.write(a.policy_fingerprint{limit=100, window=3600, burst=0, batch=1, limit_by={"path","ip"}, namespace="x", redis={key_prefix="kong:rl"}})
')
echo "顺序[ip,path]=$F1  顺序[path,ip]=$F2"
report "$([ -n "$F1" ] && [ "$F1" != "$F2" ] && echo true || echo false)" "维度顺序不同 ⇒ 指纹不同 ⇒ 不同桶"

echo
echo "===== dims 汇总: PASS=$PASS FAIL=$FAIL ====="
[ "$FAIL" -eq 0 ] || die "存在失败场景"
ok "全部维度场景通过"
