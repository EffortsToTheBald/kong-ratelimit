#!/usr/bin/env bash
# ============================================================
# redis-password-e2e.sh —— 关口六任务 2：redis.password 端到端验证
#
# 覆盖（Kong 3.6 OSS，schema password = encrypted+referenceable+len_min=0）：
#   A. 明文密码 + AUTH：临时 Redis(:6380, requirepass) 授权放行 200
#   B. 密码错误：AUTH 失败 ⇒ Fail-close 503（fault_tolerant=false）
#   C. vault 引用：password = {vault://env/kong-log-level}（解析为
#      kong 容器内环境变量 KONG_LOG_LEVEL=notice，Kong 3.6 内建 env vault）
#      ⇒ 引用可解析且授权放行 200
# 前置：docker compose up -d（redis + kong1 健康）；临时 Redis 在 redis 容器内
#       以 6380 端口启动，脚本结束 shutdown 清理。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }

# ---- 前置 ----
docker compose exec -T redis redis-cli ping >/dev/null 2>&1 || { bad "Redis 不可用"; exit 1; }

# ---- 重启 kong1 加载新 schema（schema.lua 属于插件代码；POST /config 只重建
#      iterator、不重建 Lua VM，须重启使 encrypted/referenceable 生效）----
docker compose restart kong1 >/dev/null 2>&1
for i in $(seq 1 30); do
  curl -fsS --max-time 2 "http://localhost:8031/status" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --max-time 5 "http://localhost:8031/status" >/dev/null \
  || { bad "kong1 重启后未就绪"; exit 1; }
ok "前置：kong1 已重启（新 schema 加载）"

# ---- 启动临时 Redis（:6380，密码 = notice，与 KONG_LOG_LEVEL 一致供 Case C 解析）----
docker compose exec -d redis sh -c 'redis-server --port 6380 --requirepass notice --save "" --appendonly no' </dev/null
sleep 1
cleanup() {
  docker compose exec -T redis sh -c 'redis-cli -p 6380 -a notice shutdown nosave >/dev/null 2>&1 || true' </dev/null
}
trap cleanup EXIT
docker compose exec -T redis sh -c 'redis-cli -p 6380 -a notice ping' </dev/null 2>/dev/null | grep -q PONG \
  || { bad "临时 Redis(:6380) 启动失败"; exit 1; }
ok "前置：临时 Redis :6380（requirepass）启动"

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

hit() { # hit <path> —— 返回 http_code
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://localhost:8030$1"
}

wait_code() { # wait_code <path> <expected> —— POST /config 触发 reload 后新旧 Worker 短暂共存
  local expected="$2" code
  for _ in $(seq 1 15); do
    code=$(hit "$1")
    if [ "$code" = "$expected" ]; then echo "$code"; return 0; fi
    sleep 1
  done
  echo "$code"
}

# ---- Case A：vault 引用（referenceable 端到端）----
if push_cfg "pwvault$$" '"{vault://env/kong-log-level}"'; then
  code=$(wait_code "/pw-pwvault$$" 200)
  if [ "$code" = "200" ]; then
    ok "Case A：password={vault://env/kong-log-level} 解析成功且 AUTH 放行（HTTP=200）"
  else
    bad "Case A：vault 引用解析/授权失败（HTTP=$code）"
  fi
else
  bad "Case A：Admin API 拒绝 vault 引用（referenceable 未生效）"
fi

# ---- Case B：明文密码正路径 ----
if push_cfg "pwplain$$" '"notice"'; then
  code=$(wait_code "/pw-pwplain$$" 200)
  if [ "$code" = "200" ]; then
    ok "Case B：明文密码 AUTH 放行（HTTP=200）"
  else
    bad "Case B：明文密码授权失败（HTTP=$code）"
  fi
else
  bad "Case B：Admin API 拒绝明文密码配置"
fi

# ---- Case C：密码错误 ⇒ Fail-close 503（不伪装 429）----
if push_cfg "pwwrong$$" '"wrong-pass"'; then
  code=$(wait_code "/pw-pwwrong$$" 503)
  if [ "$code" = "503" ]; then
    ok "Case C：密码错误 ⇒ Fail-close 503（既有故障语义）"
  else
    bad "Case C：密码错误未返回 503（HTTP=$code）"
  fi
else
  bad "Case C：Admin API 拒绝错误密码配置（应接受，运行时才失败）"
fi

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
