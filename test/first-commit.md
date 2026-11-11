# 手动测试记录与剧本 —— Phase 1 核心正确性基线（first-commit）

**日期**：2026-11-11
**执行人**：项目作者（按本剧本逐 case 手动执行）
**结论**：✅ **全部通过**（环境准备 + 11 个 case，无失败项）
**对应变更**：`openspec/changes/phase1-correctness-baseline`（22/22 任务，commit 链 `3d06fdf..41b10f9`）
**自动化验收报告**：`reports/phase-1-correctness.md`（本文档为该报告的人工复核与可复现剧本）

---

## 一、结果总表

| # | Case | 验收要点 | 结果 |
|---|---|---|---|
| 1 | 单节点基础令牌桶（limit=5/60s） | 前 5 个 200、第 6 个起 429；429 带 `Retry-After`（≈11~12s）与 `X-RateLimit-*` 头 | ✅ |
| 2 | batch=1 三节点严格配额 | 100/350/0；每节点 150 断言过；日志 `local_hit=0`、`local_fill=0`、`redis_grant=450` | ✅ |
| 3 | batch=20 不超发与下界 | allowed ∈ [40,100] 且永不超 100；隔离协议下稳定在 100，历史波动不复现 | ✅ |
| 4 | 跨配置隔离（策略指纹） | 同 namespace 切 limit 1000→100 后恰放行 ≤100（修复前同场景 116）；KEYS 出现两个不同 `p=` 桶 | ✅ |
| 5 | Redis 故障默认 Fail-Closed | 503 `rate limiter unavailable`；无上游响应头；日志 `failing closed`，无 traceback/500 | ✅ |
| 6 | 显式容错 degraded | 200 + `X-RateLimit-Status: degraded` + 已达上游；恢复后无标记；日志 `failing open` | ✅ |
| 7 | 令牌补充（rate=1/s） | 耗尽后等 5s 恰 4~5 个 200（=⌊elapsed×rate⌋）；桶 tokens ≤ burst=60 | ✅ |
| 8 | 时间回拨不重复计费 | 预置未来 ts → 请求后 tokens −1、**ts 保持未来值不被覆盖**、无补充 | ✅ |
| 9 | 伪造 XFF 不换桶 | `bench/xff.sh`：200=1、429=19、PASS | ✅ |
| 10 | namespace 轮次隔离 + 每节点断言 | 两轮 namespace 段不同、同策略指纹一致（e891f3c2）；断言 10/10/10 通过 | ✅ |
| 11 | 指纹性质（10 断言） | `FINGERPRINT_PROPS_OK base=25c15179 limit1000=8039753e` | ✅ |

---

## 二、环境准备与隔离前奏

```bash
cd /home/tdohs/kong/kong-ratelimit

# docker 权限：报 permission denied 时先执行一次 newgrp docker 或重开终端（usermod 已生效）
docker compose ps                              # 期望：5 个容器 running / healthy
docker compose exec redis redis-cli ping       # 期望：PONG
```

**隔离前奏（每个 Case 开头都执行）：**

```bash
docker compose restart kong1 kong2 kong3
sleep 20 && curl -s -o /dev/null -w 'kong1 ready: %{http_code}\n' localhost:8031/status   # 期望 200
docker compose exec redis redis-cli FLUSHDB          # 期望 OK
```

> `bench/common.sh` 含 bash 数组，**必须在 bash 中 source**（zsh 会报错）。
> 测试完恢复初始配置：`restart kong×3` 即回到 `kong.yml`（limit=1000/60s，batch=auto，fault_tolerant=false）。

---

## 三、Case 详细剧本（命令 + 验收 + 结果）

### Case 1｜单节点基础令牌桶（含 Retry-After）

```bash
source bench/common.sh
apply_config "$(kong_config_json 5 60 1 true manual-c1)"    # limit=5/60s, batch=1
sleep 2
for i in $(seq 1 8); do curl -s -o /dev/null -w '%{http_code} ' localhost:8030/echo; done; echo
curl -is localhost:8030/echo | head -8                       # 看第 6 个请求的 429 响应头
```

**验收**：
- [x] 前 5 个请求 `200`，第 6–8 个 `429`
- [x] 429 响应含 `Retry-After`（≈11~12s = (1−tokens)/rate，rate=5/60）和 `X-RateLimit-*` 头
- [x] 429 响应体 JSON：`{"message":"API rate limit exceeded",...}`

**结果：✅ 通过**

### Case 2｜batch=1 三节点严格全局配额（测试 A+B）

```bash
./bench/quota.sh -l 100 -b 1 -p 150        # 记下输出里的 namespace=rl-xxxx
NS=<替换成刚才打印的 namespace>
docker compose logs kong1 kong2 kong3 | grep "$NS" > /tmp/c2.log
grep -c local_hit  /tmp/c2.log             # 期望 0
grep -c local_fill /tmp/c2.log             # 期望 0
grep -c redis_grant /tmp/c2.log            # 期望 450
```

**验收**：
- [x] `allowed=100 limited=350 other=0 total=450`
- [x] `每节点请求数断言通过：kong1/2/3 各 150 次`
- [x] 日志：`local_hit=0`、`local_fill=0`、`redis_grant=450`（每请求都经过 Redis，无一走本地库存）

**结果：✅ 通过**

### Case 3｜batch=20 不超发与下界

```bash
./bench/quota.sh -l 100 -b 20 -p 150       # 多跑几轮，每轮都先做隔离前奏
```

**验收**：
- [x] 每轮 `allowed ∈ [40, 100]` 且永不 > 100（不超发）
- [x] `other=0`、每节点断言通过
- [x] 隔离协议下各轮稳定在 100（历史上 10/82/45 波动来自跨轮污染，不复现）

**结果：✅ 通过**

### Case 4｜跨配置隔离（策略指纹，重点）

```bash
# 同一 namespace 连续两轮不同 limit（不能用 quota.sh，它每轮换 namespace）：
source bench/common.sh
NS=manual-c4
apply_config "$(kong_config_json 1000 3600 20 true "$NS")"; sleep 2
for p in 8030 8010 8020; do for i in $(seq 1 150); do curl -s -o /dev/null -w '%{http_code}\n' localhost:$p/echo; done; done | sort | uniq -c
# ↑ 约 30~45 秒，期望 450 个 200

apply_config "$(kong_config_json 100 3600 20 true "$NS")"; sleep 2     # 同 namespace 切 limit
for p in 8030 8010 8020; do for i in $(seq 1 150); do curl -s -o /dev/null -w '%{http_code}\n' localhost:$p/echo; done; done | sort | uniq -c

docker compose exec redis redis-cli KEYS 'kong:rl:*manual-c4*'
```

**验收**：
- [x] 第二轮 `200 ≤ 100`（修复前同场景实测 **116** 超发）
- [x] KEYS 出现两个 key：namespace 相同、`p=` 指纹不同（`8039753e` / `50780f62`）
- [x] limit=100 的桶 tokens 被打到 ≈0

**结果：✅ 通过**

### Case 5｜Redis 故障 → 默认 Fail-Closed（503）

```bash
source bench/common.sh
apply_config "$(kong_config_json 100 3600 1 true manual-c5)"; sleep 2
docker compose stop redis
curl -is localhost:8030/echo | head -6
docker compose logs kong1 --since 2m | grep -E "failing|grant failed" | tail -2
docker compose start redis
```

**验收**：
- [x] HTTP **503**，响应体 `{"message":"rate limiter unavailable"}`
- [x] 响应无 `X-App-Name`/`X-App-Version`（请求未达上游）
- [x] 日志 `redis grant failed`（error）+ `failing closed`，无 `stack traceback` / `attempt to index`
- [x] 三节点各 curl 一次，全部 503

**结果：✅ 通过**

### Case 6｜Redis 故障 → 显式容错（degraded 放行）

```bash
# 配置需显式带 fault_tolerant:true（kong_config_json 生成的已是显式 false），手工构造：
source bench/common.sh
JSON=$(python3 -c "
import json
cfg={'limit':100,'window':3600,'batch':1,'limit_by':['ip'],'namespace':'manual-c6','fault_tolerant':True,'redis':{'host':'redis','port':6379,'database':0,'timeout':1000}}
print(json.dumps({'_format_version':'3.0','services':[{'name':'echo','url':'http://echo:5678','routes':[{'name':'echo-route','paths':['/echo'],'strip_path':False,'plugins':[{'name':'rate-limit-advanced','config':cfg}]}]}]}))
")
apply_config "$JSON"; sleep 2
docker compose stop redis
curl -is localhost:8030/echo | head -6
docker compose start redis; sleep 2
curl -is localhost:8030/echo | grep -E "HTTP|X-RateLimit-Status|X-App-Name"   # 恢复后
docker compose logs kong1 --since 2m | grep "failing open" | tail -1
```

**验收**：
- [x] Redis 停止时：HTTP **200** + `X-RateLimit-Status: degraded` + `X-App-Name: http-echo`（已达上游）
- [x] 恢复后：200，无 degraded 头
- [x] 日志出现 `limiter unavailable, failing open`（warn）

**结果：✅ 通过**

### Case 7｜令牌补充（测试 D，rate=1 令牌/秒）

```bash
source bench/common.sh
apply_config "$(kong_config_json 60 60 1 true manual-c7)"    # rate = 60/60 = 1/s，burst=60
sleep 2
for i in $(seq 1 60); do curl -s -o /dev/null -w '%{http_code} ' localhost:8030/echo; done; echo
sleep 5
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' localhost:8030/echo; done; echo
docker compose exec redis redis-cli KEYS 'kong:rl:*manual-c7*'
# 把上面的 key 代入：
docker compose exec redis redis-cli HGETALL 'kong:rl:{manual-c7:p=<指纹>:ip=172.20.0.1}'
```

**验收**：
- [x] 耗尽阶段：200 个数 ≈ 60 + 耗时秒数（手敲慢会多补几个，≤67 都算对），之后连续 429
- [x] 等 5 秒后：恰 **4~5 个 200**（= ⌊elapsed × 1⌋），然后回到 429
- [x] 桶里 `tokens ≤ 60`（burst 封顶），`ts` 已更新

**结果：✅ 通过**（自动化参照值：5.004s → 恰 5 个；手动按 4~5 个判定）

### Case 8｜时间回拨不重复计费

```bash
source bench/common.sh
apply_config "$(kong_config_json 60 60 1 true manual-c8)"; sleep 2
curl -s -o /dev/null -w '%{http_code}\n' localhost:8030/echo      # 建桶
KEY=$(docker compose exec redis redis-cli --scan --pattern 'kong:rl:*manual-c8*')
docker compose exec redis redis-cli HGETALL "$KEY"               # tokens=59
FUTURE=$(( $(date +%s) + 3600 ))
docker compose exec redis redis-cli HSET "$KEY" ts "$FUTURE"      # ts 改成 1 小时后
curl -s -o /dev/null -w '%{http_code}\n' localhost:8030/echo      # 再打一发
docker compose exec redis redis-cli HGETALL "$KEY"
```

**验收**：
- [x] 第二次请求 200，`tokens` 恰好 59→58（无任何补充）
- [x] `ts` 仍等于 $FUTURE 的值——未被覆盖成当前时间（旧代码会覆盖，时钟追上后这一小时会被补两遍）

**结果：✅ 通过**

### Case 9｜伪造 X-Forwarded-For 不换桶

```bash
./bench/xff.sh
```

**验收**：
- [x] 输出 `200=1  429=19  total=20` + `PASS：伪造 XFF 未产生新桶`
- [x] （可选手动复现）`limit=1 batch=1` 配置下，带不同 XFF 连发 curl，仅首个 200

**结果：✅ 通过**

### Case 10｜namespace 轮次隔离 + 每节点断言（内置）

```bash
./bench/quota.sh -l 1000000 -b 1 -p 10
./bench/quota.sh -l 1000000 -b 1 -p 10
docker compose exec redis redis-cli KEYS 'kong:rl:*'
```

**验收**：
- [x] 两轮日志的 `namespace=rl-<时间戳>-<pid>` 不同
- [x] KEYS 出现两个 namespace 段不同的 key，且**指纹段相同**（`p=e891f3c2`）
- [x] 两轮都打印 `每节点请求数断言通过：kong1/2/3 各 10 次`

**结果：✅ 通过**

### Case 11｜指纹性质（一条命令全验）

```bash
docker compose exec kong1 resty -e '
local a = require "kong.plugins.rate-limit-advanced.lib.algorithm"
local function clone(t) local c={} for k,v in pairs(t) do if type(v)=="table" then local d={} for i,x in ipairs(v) do d[i]=x end c[k]=d else c[k]=v end end return c end
local base = {limit=100, window=3600, burst=0, batch=20, limit_by={"ip","path"}, namespace="rl", redis={key_prefix="kong:rl"}}
local fp = a.policy_fingerprint; local b
b=clone(base); b.limit=200;   assert(fp(base)~=fp(b),"limit")
b=clone(base); b.window=60;   assert(fp(base)~=fp(b),"window")
b=clone(base); b.burst=200;   assert(fp(base)~=fp(b),"burst")
b=clone(base); b.limit_by={"path","ip"}; assert(fp(base)~=fp(b),"order")
b=clone(base); b.limit_by={"ip","path","header"}; b.header_name="X-Api"; assert(fp(base)~=fp(b),"header dim")
b=clone(base); b.batch=5;     assert(fp(base)==fp(b),"batch must not change")
b=clone(base); b.burst=100;   assert(fp(base)==fp(b),"burst 0 == limit")
local h1=clone(base); h1.limit_by={"header"}; h1.header_name="X-A"
local h2=clone(base); h2.limit_by={"header"}; h2.header_name="X-B"
assert(fp(h1)~=fp(h2),"header_name")
local big=clone(base); big.limit=1000; big.limit_by={"ip"}
assert(#fp(big)==8 and fp(big):match("^[0-9a-f]+$"),"8 hex")
assert(#fp(base)==8 and fp(base):match("^[0-9a-f]+$"),"8 hex")
print("FINGERPRINT_PROPS_OK base="..fp(base).." limit1000="..fp(big))
'
```

**验收**：末行输出 `FINGERPRINT_PROPS_OK base=25c15179 limit1000=8039753e`（10 条断言全过、无 assert 报错）

**结果：✅ 通过**

---

## 四、排查工具速查

| 看什么 | 命令 |
|---|---|
| 容器状态 | `docker compose ps` |
| 三节点管理面 | `for p in 8031 8011 8021; do curl -s -o /dev/null -w "%{http_code} " localhost:$p/status; done` |
| 全部桶 | `docker compose exec redis redis-cli KEYS 'kong:rl:*'` |
| 某桶状态（tokens/ts） | `docker compose exec redis redis-cli HGETALL '<key>'` |
| 找某轮的 key | `docker compose exec redis redis-cli --scan --pattern 'kong:rl:*<namespace片段>*'` |
| 清库（仅测试环境！） | `docker compose exec redis redis-cli FLUSHDB` |
| 某轮日志（按 namespace 过滤，最干净） | `docker compose logs kong1 kong2 kong3 \| grep '<namespace>'` |
| 决策分布 | 上条接 `\| grep -o 'granted=[0-9]*' \| sort \| uniq -c` |
| 本地库存命中数 | 上条接 `\| grep -c local_hit` |
| Redis 授予次数 | 上条接 `\| grep -c redis_grant` |
| fill 分布 | 上条接 `\| grep -o 'fill=[0-9]*' \| sort \| uniq -c` |
| 异常栈（必须永远为 0） | `docker compose logs kong1 --since 5m \| grep -c traceback` |
| 故障分支日志 | `docker compose logs kong1 --since 5m \| grep -E 'failing (open\|closed)'` |
| 状态码统计（curl 循环后） | `\| sort \| uniq -c` |
| 下发配置（免手写 JSON） | `source bench/common.sh; apply_config "$(kong_config_json <limit> <window> <batch> true <ns>)"` |
| 恢复 kong.yml 初始配置 | `docker compose restart kong1 kong2 kong3` |
| 手动指定 fault_tolerant 的配置 | 用 Case 6 的 python3 构造法 |

**两个高频坑**：
1. Redis 停止时日志显示 `DNS resolution failed`——容器停了名字解析不到，这就是"Redis 不可达"的真实故障形态，不是另一种 bug。
2. 数字对不上第一件事查**隔离前奏**：同策略下 FLUSHDB 后旧本地库存仍有效（合法语义、少发方向），不清 worker 库存会污染结果。

---

## 五、期望值锚点（回归对比用）

| 项 | 值 |
|---|---|
| 指纹 limit=100/window=3600/burst→100/limit_by=ip,path | `25c15179` |
| 指纹 limit=1000/…/limit_by=ip | `8039753e` |
| 指纹 limit=100/…/limit_by=ip | `50780f62` |
| 指纹 limit=1000000/…/limit_by=ip | `e891f3c2` |
| key 格式 | `kong:rl:{<ns>:p=<8位hex>:ip=172.20.0.1}` |
| batch=1 基线（450 请求） | allowed=100 / limited=350 / other=0 / redis_grant=450 |
| batch=20 基线（隔离协议下） | allowed=100（区间 [40,100]） |
| 补充速率（limit=60/60s） | 5.004s → 5 个令牌 |
| 故障日志锚点 | `algorithm.lua:136 grant failed` → `handler.lua:29 failing open` / `handler.lua:34 failing closed` |

---

## 六、提交链（每组一个 commit，组级可回滚）

```
0ef735a docs: 手动测试记录 test/first-commit.md（本文档）
41b10f9 组8: Phase 1 集成验收（测试 A-D + 报告）
5b33762 组7: IP 维度回归测试（bench/xff.sh）
912eab2 组6: 压测脚本收敛（namespace 隔离 + 每节点断言）
4dd3576 组5: Fail-Closed 默认（schema + kong.yml + 文档）
f830672 组4: 策略指纹进 Key（FNV-1a + 双桶隔离实测）
04cad54 组3: 决策主流程修复（nil 判定 / batch=1 短路 / get_ip）
f081647 组2: Redis Lua 时间戳单调（双源同步）
352b7fe 组1: 回滚基线与环境自检
3d06fdf baseline: P0 修复前回滚锚点
```

---

## 七、遗留事项（下一 change 输入）

- `rule.md` §3.2/§3.3 key 格式示例尚未含 `p=` 指纹（作者原始文档，待作者确认后同步）
- P1 批：reset/remaining 口径（batch=1 时 Remaining 恒 0）、EVALSHA、Retry-After 上限、429 日志、Redis 返回值防御校验、header_name schema 校验、shared dict 降级告警
- Phase 4：batch×RPS 矩阵、非均匀流量滞留、本地库存租赁生命周期（须防重复归还）、`bench/out` 权限预检
- Phase 5：Prometheus 指标、结构化日志、长稳/节点重启场景

**人工验收：通过（本文档即验收记录与可复现剧本）。**
