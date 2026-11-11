# 手动测试剧本 —— Phase 2 多维语义与可观测基线（phase2-manual）

**日期**：2026-11-11
**状态**：⏳ 待执行（执行后逐项勾选，并回填结果总表）
**对应变更**：`openspec/changes/phase2-dimensions-and-semantics`（20/20 任务已完成，自动化验收见 `reports/phase-2-dimensions-and-semantics.md`）
**配套**：Phase 1 人工记录见 `test/first-commit.md`

> 规矩与 Phase 1 相同：**每个 Case 前先跑隔离前奏**；在 bash 中执行（zsh 不兼容 `bench/common.sh` 的数组）；docker 报 permission denied 先 `newgrp docker`。
> 每个 Case 的「目的」说明它对应的设计决策（D1–D9，见 change 的 design.md）或 review-phase-0 的 P1 编号——测试与取舍可互相追溯。

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

**目的**：验证 D1（Reset=下一令牌可用时刻）。对应 review P1-2 + P1-9：旧实现的 `Reset = now + window` 是伪窗口语义——客户端同时拿到 `Reset−now=3600` 与 `Retry-After=36` 两个自相矛盾的数。选 `limit=100/window=3600` 是为了造出便于肉眼核对的等待值（rate=0.0278/s ⇒ wait≈36s）：若实现仍是旧语义，差值 3600≠36 一眼识破；若 handler 忘了用封顶后的 Retry-After 推导 Reset，同样红。

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

**目的**：验证 D2 的边界行为。选 `limit=1/window=3600` 是**极端小 rate**：wait=(1−0)/0.001=3600，正好压在封顶边界上——唯一能同时验证"cap 生效"和"cap 不误伤"的配置（正常配置下 wait 数学上 ≤ window/limit ≤ window，cap 是冗余保险，这条钉住"保险确实无害"）。若 cap 写错（min/max 反了、window 取错字段），这里会看到异常值。

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

**目的**：D1 最易翻车处——两条路径的 Reset **来源不同**（快路径=本地近似，慢路径=Redis wait），口径漂移是典型 bug。用 `batch=20` 造出快路径（第 2 发走本地库存），`1000/60` 让 rate 大到 wait=0。序列设计：第 1 发库存必空（慢路径），第 2 发必命中（快路径）——两发都应 Reset≈now。若快路径漏改（仍回 now+window）或慢路径回旧 reset_at，立刻暴露；`Remaining 19→18` 顺带确认租约语义未被改坏。

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

**目的**：验证 D4（P1-4）。坏配置原来能下发成功、到运行时才 500——错误暴露在生产流量上；entity_checks 把校验前移到 Admin API。**只发坏配置不够**：校验器最常见的翻车是"误伤合法配置"（contains 对数组不生效 → 恒拒绝/恒放行），所以必须有对照（带 header_name 的 201、既有 [ip] 的 201）。400 的错误体还要看字段定位（`config.header_name: required field missing`）——证明命中原因是本规则而非别的校验。

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

**目的**：验证 D8（P1-7）。429（确定性拒绝）与 503/降级（故障）若日志不分，排查时分不清"拒绝率高是策略生效还是故障余波"。隐藏断言：**日志级别必须是 notice**——`KONG_LOG_LEVEL=notice` 下 nginx 不输出 info 级，若实现用了 `log.info`，这条 grep 什么都看不到。级别选错、放错分支、缺字段（key/limit/batch）都逃不掉。

```bash
docker compose logs kong1 --since 10m | grep '429 key=' | tail -3
```

**验收**：
- [ ] 日志形如 `rate-limit-advanced: 429 key=<限流键> limit=100 batch=1`
- [ ] 该日志与故障日志（`failing closed/open`）能一眼区分

结果：＿＿＿＿

## Case F｜Redis 防御校验单测

**目的**：验证 D3。Redis 返回畸形数据时，旧实现 `tonumber(x) or 0` 会把 granted 静默当 0（错误 429）或把畸形当合法（异常放行）——数据不可信时不应做任何确定性决策。**为什么是单测不是 E2E**：无法让真 Redis 吐畸形数据（脚本是自己的），注入需要假 Redis 服务器，成本高收益低；校验函数是纯函数，单测能喂遍所有畸形形态——"测试方式与被测对象对齐"。样例每条对应一类防御面缺口：非 table / 长度错 / 非数值 / 越界（>want、<0、小数）/ wait<0。

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

**目的**：验证 D5 的负向（P1-8）。降级到 worker 私有表是有意设计（无 shared dict 也能跑），但此前完全静默——运维不知道精度已从"节点级"掉到"worker 级"。本条测**正常环境 0 条告警**：告警噪音会让人忽略真问题。正向（真起一个无 shared dict 的临时容器）在自动化验收已覆盖（report §7-16），手动不做是因为 `docker run` 临时容器成本不成比例。

```bash
docker compose logs kong1 kong2 kong3 --since 30m | grep -c 降级    # 期望 0
```

**验收**：
- [ ] 0 条（降级告警只在缺失 shared dict 的启动出现；正向验证方式见 `reports/phase-2-dimensions-and-semantics.md` §7-16）

结果：＿＿＿＿

## Case H｜consumer 维度（key-auth + 三身份独立）

**目的**：验证 D6/D7 的 consumer 场景（MVP "Client ID 粒度"实证）。这是**唯一依赖"其他插件先执行"的维度**：若 key-auth（1250）没先于限流（1002）执行，`get_consumer()` 拿不到身份、全落 anon——PRIORITY 设计正确性的直接证据。配置里的 `anonymous` 是关键：限流插件看不到"没过认证"的请求（key-auth 会先 401），要让未认证请求进入限流并落 anon 桶，必须用 key-auth 的 anonymous consumer 机制放行无 key 请求。序列 alice→bob→anon 各 200/429：若 consumer 取值错（同一 id）会看到 200,429,429…；若 anon 与 alice 共桶，顺序会乱。`attempt to call=0` 排除 PDK 异常干扰。

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

**目的**：验证 route/service 维度（spec ADDED）。取值是 UUID——若 `dim_value` 返回 "-"（未命中）或 key 里没有该段，按 route 限流会**静默退化为全站单桶**。这条的杀招不是看 200/429，而是**直接检查 key 内容**：`route=<uuid>` 出现在 hash tag 里才是铁证。`limit=1` 够用（一发 200 一发 429），重点在 key 形状；用 `--scan` 是生产习惯（KEYS 会阻塞 Redis）。

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

**目的**：以上 A–I 是手动抽样，dims.sh 是**固化成断言的回归**：7 场景任何人一条命令复测。手动测试与自动化回归的关系是"手动确认体验与边界，脚本保证可重复"——本剧本做完后，以后每次改代码跑 `dims.sh` + `quota.sh` 即为多维 + 配额的回归底线。

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
