#!/usr/bin/env bash
# E5：IP 维度信任语义回归 —— 伪造 X-Forwarded-For 不得产生新桶（P0-3 / D6）
#
# 背景：ip 维度取值 = kong.client.get_forwarded_ip() = realip 处理后的 remote_addr。
# 默认部署（trusted_ips 未配置 = trust none）下 nginx realip 不改写 remote_addr，
# 所以 ip 取值就是 TCP 直连对端 IP —— 客户端伪造的 XFF 只是普通请求头，不参与限流 key。
#
# 期望：同一来源 IP 连发 N 个请求、各带不同伪造 XFF → 仅第 1 个放行，其余全部 429。
# （若该行为失效，说明 ip 维度信任了不可信来源的转发头。）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

N=20
assert_prerequisites

NS="rl-xff-$(date +%s)-$$"
log "下发配置：limit=1 window=3600 batch=1 namespace=$NS"
apply_config "$(kong_config_json 1 3600 1 true "$NS")"
sleep 2

log "打流量：$N 个请求，各带不同伪造 X-Forwarded-For"
codes=""
for i in $(seq 1 "$N"); do
    c=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "X-Forwarded-For: 10.255.$((i / 250)).$((i % 250 + 1))" \
        http://localhost:8030/echo)
    codes="$codes $c"
done
echo "状态码序列：$codes"

ok200=$(echo "$codes" | tr ' ' '\n' | grep -c '^200$' || true)
r429=$(echo "$codes" | tr ' ' '\n' | grep -c '^429$' || true)
echo "200=$ok200  429=$r429  total=$N"

if [ "$ok200" -eq 1 ] && [ "$r429" -eq "$((N - 1))" ]; then
    ok "PASS：伪造 XFF 未产生新桶（全部命中同一 IP 桶）"
else
    die "FAIL：200=$ok200 429=$r429（伪造 XFF 疑似绕过，或出现其他异常状态码）"
fi
