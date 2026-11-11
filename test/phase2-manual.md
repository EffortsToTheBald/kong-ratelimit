# 手动测试剧本 —— Phase 2 多维语义与可观测基线（phase2-manual）

**日期**：2026-11-11
**状态**：⏳ 待执行（执行后逐项勾选，并回填结果总表）
**对应变更**：`openspec/changes/phase2-dimensions-and-semantics`（20/20 任务已完成，自动化验收见 `reports/phase-2-dimensions-and-semantics.md`）
**配套**：Phase 1 人工记录见 `test/first-commit.md`

> 规矩与 Phase 1 相同：**每个 Case 前先跑隔离前奏**；在 bash 中执行（zsh 不兼容 `bench/common.sh` 的数组）；docker 报 permission denied 先 `newgrp docker`。

---

## 0. 准备与隔离前奏

```bash
cd /home/tdohs/kong/kong-ratelimit
docker compose ps                 # 期望 5 容器 running/healthy

# 隔离前奏（每个 Case 开头执行）：
docker compose restart kong1 kong2 kong3
sleep 20 && curl -s -o /dev/null -w 'ready: %{http_code}\n' localhost:8031/status   # 期望 200
docker compose exec redis redis-cli FLUSHDB    # 期望 OK
```

---

## Case A｜429 同口径（Reset−now == Retry-After）

```bash
source bench/common.sh
apply_config "$(kong_config_json 100 3600 1 true manual-p2a)"; sleep 2
docker compose exec redis redis-cli FLUSHDB
for i in $(seq 1 100); do curl -s -o /dev/null localhost:8030/echo; done
NOW=$(date +%s)
curl -is localhost:8030/echo | tr -d '\r' | grep -iE 'HTTP/|Retry-After|X-RateLimit-Reset'
echo "now=$NOW"
```

**验收**：
- [ ] HTTP 429
- [ ] `Retry-After` = 36±1（rate=100/3600）
- [ ] `X-RateLimit-Reset − now` == Retry-After（±1 秒）——同口径（旧语义里 Reset 会是 now+3600）

结果：＿＿＿＿

## Case B｜Retry-After 封顶

```bash
apply_config "$(kong_config_json 1 3600 1 true manual-p2b)"; sleep 2
docker compose exec redis redis-cli FLUSHDB
curl -s -o /dev/null localhost:8030/echo
curl -is localhost:8030/echo | tr -d '\r' | grep -iE 'HTTP/|Retry-After'
```

**验收**：
- [ ] 429 且 `Retry-After: 3600`（= window 上限，且不再更大）

结果：＿＿＿＿

## Case C｜快/慢路径 Reset = "下一令牌已可用"

```bash
apply_config "$(kong_config_json 1000 60 20 true manual-p2c)"; sleep 2
docker compose exec redis redis-cli FLUSHDB
date +%s
curl -is localhost:8030/echo | tr -d '\r' | grep -i 'X-RateLimit-'
curl -is localhost:8030/echo | tr -d '\r' | grep -i 'X-RateLimit-'
```

**验收**：
- [ ] 第 1 发（slow path）：`Remaining: 19`
- [ ] 第 2 发（fast path）：`Remaining: 18`
- [ ] 两发 `X-RateLimit-Reset` 都 ≈ 上面打印的 `date +%s`（有库存 ⇒ 下一令牌已可用；不再是旧语义的 now+60）

结果：＿＿＿＿

## Case D｜header_name 前置校验（下发即 400）

```bash
python3 -c "
import json
cfg={'limit':100,'window':3600,'batch':1,'limit_by':['header'],'namespace':'manual-p2d-bad','redis':{'host':'redis','port':6379,'database':0,'timeout':1000}}
print(json.dumps({'_format_version':'3.0','services':[{'name':'echo','url':'http://echo:5678','routes':[{'name':'echo-route','paths':['/echo'],'strip_path':False,'plugins':[{'name':'rate-limit-advanced','config':cfg}]}]}]}))
" > /tmp/bad.json
curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8031/config -H 'Content-Type: application/json' -d @/tmp/bad.json
```

**验收**：
- [ ] HTTP **400**，错误体含 `header_name` 和 `required field missing`
- [ ] （对照）把 `"limit_by":["header"]` 改成带 `"header_name":"X-Tenant"` 的配置再 POST → 201

结果：＿＿＿＿

## Case E｜429 判定日志

```bash
docker compose logs kong1 --since 10m | grep '429 key=' | tail -3
```

**验收**：
- [ ] 日志形如 `rate-limit-advanced: 429 key=<限流键> limit=100 batch=1`
- [ ] 该日志与故障日志（`failing closed/open`）能一眼区分

结果：＿＿＿＿

## Case F｜Redis 防御校验单测

```bash
docker compose exec kong1 resty -e '
local rm = require "kong.plugins.rate-limit-advanced.lib.redis"
local p = rm.parse_grant_response
assert(select(1, p("x", 20)) == nil)
assert(select(1, p({1,2}, 20)) == nil)
assert(select(1, p({21,"1","1"}, 20)) == nil)   -- granted>want
assert(select(1, p({"1","y","1"}, 20)) == nil)  -- tokens 非数
assert(select(1, p({"1","1",-2}, 20)) == nil)   -- wait<0
local ok = p({20,"99.5","0"}, 20)
assert(ok and ok.granted == 20)
print("PARSE_GRANT_OK")
'
```

**验收**：输出 `PARSE_GRANT_OK`（畸形全拒、合法通过）

结果：＿＿＿＿

## Case G｜shared dict 降级告警（正常启动应静默）

```bash
docker compose logs kong1 kong2 kong3 --since 30m | grep -c 降级    # 期望 0
```

**验收**：
- [ ] 0 条（降级告警只在缺失 shared dict 的启动出现；正向验证方式见 `reports/phase-2-dimensions-and-semantics.md` §7-16）

结果：＿＿＿＿

## Case H｜consumer 维度（key-auth + 三身份独立）

```bash
NS=manual-p2h
python3 -c "
import json, sys
anon='33333333-3333-3333-3333-333333333333'
rl={'limit':1,'window':3600,'batch':1,'limit_by':['consumer'],'namespace':sys.argv[1],'redis':{'host':'redis','port':6379,'database':0,'timeout':1000}}
print(json.dumps({'_format_version':'3.0','consumers':[
 {'username':'alice','id':'11111111-1111-1111-1111-111111111111','keyauth_credentials':[{'key':'alice-key'}]},
 {'username':'bob','id':'22222222-2222-2222-2222-222222222222','keyauth_credentials':[{'key':'bob-key'}]},
 {'username':'anon-visitor','id':anon}],
 'services':[{'name':'echo','url':'http://echo:5678','routes':[{'name':'echo-auth','paths':['/auth'],'strip_path':False,
  'plugins':[{'name':'key-auth','config':{'anonymous':anon}},{'name':'rate-limit-advanced','config':rl}]}]}]}))
" "$NS" > /tmp/consumer.json
docker compose exec redis redis-cli FLUSHDB
curl -s -o /dev/null -w 'config: %{http_code}\n' -X POST localhost:8031/config -H 'Content-Type: application/json' -d @/tmp/consumer.json   # 期望 201

for r in 1 2; do curl -s -o /dev/null -w "alice-$r: %{http_code}\n" localhost:8030/auth -H 'apikey: alice-key'; done
for r in 1 2; do curl -s -o /dev/null -w "bob-$r: %{http_code}\n"   localhost:8030/auth -H 'apikey: bob-key';   done
for r in 1 2; do curl -s -o /dev/null -w "anon-$r: %{http_code}\n"  localhost:8030/auth; done
docker compose logs kong1 --since 5m | grep -c 'attempt to call'
```

**验收**：
- [ ] `config: 201`
- [ ] 序列 alice=200/429、bob=200/429、anon=200/429（三身份配额完全独立）
- [ ] `attempt to call` 计数 = 0（key-auth 1250 先于限流 1002 实证）

结果：＿＿＿＿

## Case I｜route / service 维度进 key

```bash
source bench/common.sh
apply_config "$(kong_config_json 1 3600 1 true manual-p2i '["route"]')"
docker compose exec redis redis-cli FLUSHDB
curl -s -o /dev/null localhost:8030/echo
docker compose exec redis redis-cli --scan --pattern 'kong:rl:*manual-p2i*'
# service 维度：把两处 '["route"]' 换成 '["service"]'、namespace 换成 manual-p2j 再跑一遍
```

**验收**：
- [ ] key 形如 `kong:rl:{manual-p2i:p=<8位指纹>:route=<uuid>}`
- [ ] service 版本 key 形如 `…:service=<uuid>`

结果：＿＿＿＿

## Case J｜一键全量（终态复核）

```bash
./bench/dims.sh
```

**验收**：
- [ ] `PASS=8 FAIL=0`，输出 `全部维度场景通过`

结果：＿＿＿＿

---

## 收尾

```bash
docker compose restart kong1 kong2 kong3    # 恢复 kong.yml 初始配置（Case D/H 的 POST 覆盖过运行时配置）
```

## 结果总表（执行后回填）

| Case | 内容 | 结果 |
|---|---|---|
| A | 429 同口径 | ⏳ |
| B | Retry-After 封顶 | ⏳ |
| C | 快/慢路径 Reset | ⏳ |
| D | header_name 下发即 400 | ⏳ |
| E | 429 判定日志 | ⏳ |
| F | 防御校验单测 | ⏳ |
| G | 降级告警静默 | ⏳ |
| H | consumer 三身份独立 | ⏳ |
| I | route/service 进 key | ⏳ |
| J | dims.sh 一键全量 | ⏳ |
