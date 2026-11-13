#!/usr/bin/env bash
# ============================================================
# script-cache-selfheal-e2e.sh —— 6.4 EVALSHA 缓存丢失自愈（真栈）
#
# 场景（Spec/Phase 2 冻结口径）：
#   1. 三模式各发请求：正常 EVALSHA（懒加载已完成）⇒ 200
#   2. SCRIPT FLUSH 清空 Redis 脚本缓存
#   3. 三模式再发请求：EVALSHA ⇒ NOSCRIPT ⇒ SCRIPT LOAD ⇒ 重试恰一次 ⇒ 200（自愈）
#   4. SCRIPT EXISTS 证实三个脚本均被插件重新装回缓存：
#      sha 由 sha1sum 对提取文本计算（绝不手动 SCRIPT LOAD——污染检查结果）；
#      提取文本须与插件 src 逐字节一致：Lua 长括号 [[ 后紧跟的首个换行
#      会被 Lua 剥离，故提取后必须去掉该首行换行再计算 SHA
#   5. 超时不触发 LOAD：由静态单测 evalsha-unit.sh case6 断言（本组引用其结果）
# 注意：FLUSH 后 lease 路由若命中 worker 本地库存则零 Redis ⇒ grant_lease
# 不会触发 NOSCRIPT 重载；故 post-FLUSH 的 grant_lease 验证使用新 ns 新路由
# （新指纹 ⇒ 新 Pool ⇒ 首请求必 GRANT）
# 前置：三节点健康；独立 namespace
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()   { printf '\033[32m%s\033[0m\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '\033[31m%s\033[0m\n' "$*" >&2; FAIL=$((FAIL+1)); }
report() { if [ "$1" = "true" ]; then ok "PASS: $2"; else bad "FAIL: $2"; fi; }
eq() { [ "$1" = "$2" ] && echo true || echo false; }
RC() { docker compose exec -T redis redis-cli "$@"; }
PROXY="http://localhost:8030"
RLCONFIG='"fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}'
NS="p64s$$"

ok "三模式路由（batch=1 / batch>1 / 多规则）自愈口径就绪"

cat <<EOF > /tmp/opencode/rl64-config.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"s-b1","paths":["/s-b1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-b1",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-g1","paths":["/s-g1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-g1",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-mu","paths":["/s-mu"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-mu",
     "limit":50,"window":3600,"burst":0,
     "rules":[{"limit":100,"window":3600,"limit_by":["ip"]},
              {"limit":50,"window":3600,"limit_by":["ip"]}],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl64-config.json >/dev/null \
    || { bad "节点 :$n 配置下发失败"; exit 1; }
done
ok "三路由配置下发（batch=1 / batch>1 / 多规则）"

# ---- 1. 正常请求（懒加载完成） ----
for p in s-b1 s-g1 s-mu; do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$PROXY/$p")
  report "$(eq "$c" 200)" "FLUSH 前请求 /$p ⇒ $c（应为 200，EVALSHA 正常）"
done

# ---- 2. 清空脚本缓存 ----
RC SCRIPT FLUSH >/dev/null
ok "SCRIPT FLUSH 完成（脚本缓存已清空）"

# ---- 2b. 下发新 ns 的 lease 路由（新指纹 ⇒ 新 Pool ⇒ post-FLUSH 首请求必 GRANT） ----
NS2="p64s2$$"
cat <<EOF > /tmp/opencode/rl64-config2.json
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[
  {"name":"s-b1","paths":["/s-b1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-b1",
     "window":3600,"limit":100,"batch":1,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-g1","paths":["/s-g1"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-g1",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-g2","paths":["/s-g2"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS2-g2",
     "window":3600,"limit":100,"batch":10,"burst":0,"limit_by":["ip"],$RLCONFIG}}]},
  {"name":"s-mu","paths":["/s-mu"],"strip_path":false,
   "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"$NS-mu",
     "limit":50,"window":3600,"burst":0,
     "rules":[{"limit":100,"window":3600,"limit_by":["ip"]},
              {"limit":50,"window":3600,"limit_by":["ip"]}],
     "fault_tolerant":false,"redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]}
]}]}
EOF
for n in 8031 8011 8021; do
  curl -fsS --max-time 10 -X POST "http://localhost:$n/config" \
       -H 'Content-Type: application/json' -d @/tmp/opencode/rl64-config2.json >/dev/null \
    || { bad "节点 :$n 配置2下发失败"; exit 1; }
done
ok "新 lease 路由 s-g2 下发（新 ns $NS2-g2）"

# ---- 3. FLUSH 后请求：NOSCRIPT ⇒ LOAD ⇒ 恰一次重试 ⇒ 自愈 ----
# s-g2 首请求：无本地库存 ⇒ NEED_GRANT ⇒ grant_lease NOSCRIPT 自愈
for p in s-b1 s-g2 s-mu; do
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$PROXY/$p")
  report "$(eq "$c" 200)" "FLUSH 后请求 /$p ⇒ $c（应为 200：NOSCRIPT 自愈成功；无自愈则 503）"
done

# ---- 4. SCRIPT EXISTS：三个脚本均已被插件装回缓存 ----
for name in TOKEN_BUCKET GRANT_MULTI GRANT_LEASE; do
  sha=$(python3 - "$name" <<'PYEOF'
import re, sys, hashlib
src = open('kong/plugins/rate-limit-advanced/lib/redis.lua').read()
name = sys.argv[1]
t = re.search(r'local ' + name + r' = \[\[(.*?)\]\]', src, re.S).group(1)
if t.startswith('\n'):
    t = t[1:]
print(hashlib.sha1(t.encode()).hexdigest())
PYEOF
)
  ex=$(RC SCRIPT EXISTS "$sha" | tr -d '\r')
  report "$(eq "$ex" 1)" "$name 已在脚本缓存（sha1sum=$sha EXISTS=$ex；检查前未执行 SCRIPT LOAD）"
done

# ---- 5. 日志：无自愈失败痕迹 ----
logs=$(docker compose logs kong1 --since 3m 2>&1 || true)
report "$([ "$(echo "$logs" | grep -c 'script still missing after reload')" -eq 0 ] && echo true)" "日志无 'script still missing after reload'（自愈未失败）"
report "$([ "$(echo "$logs" | grep -c 'script load failed')" -eq 0 ] && echo true)" "日志无 'script load failed'"

printf '\n===== 汇总: PASS=%s FAIL=%s =====\n' "$PASS" "$FAIL"
[ "$FAIL" = "0" ]
