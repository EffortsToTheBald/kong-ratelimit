# Phase 0 — 现有实现全面审查

**审查对象：** `kong-ratelimit/`（Kong 3.6.1 + Redis 7 + OpenResty）
**审查方式：** 静态代码审查 + 运行时事实核实 + 已发生故障的复盘
**审查日期：** 2026-11-11
**状态：** 仅审查，未修改任何代码

---

## 0. 结论摘要

1. **核心算法（Token Bucket）与 Redis 原子扣减是正确的**：单次 EVAL 内完成读-算-扣-写，多节点共享同一 key 时总额度不随节点数放大。已有实测支持（450 请求 → 恰好 100 放行）。
2. **真正的正确性风险不在算法，而在"状态生命周期"**：Key 不含策略指纹，导致配置变更后旧桶、旧本地库存继续生效。已实测到 `allowed=116 > limit=100`。
3. **当前默认是 Fail-Open，与新规范要求的 Fail-Closed 相反**；且测试体系尚不能证明"全局额度"这一核心命题（每节点请求数不受控）。

---

## 1. 审查范围与运行时核实

### 1.1 已核对的文件

| 文件 | 结论 |
|---|---|
| `kong/plugins/rate-limit-advanced/handler.lua` | 已读，71 行 |
| `kong/plugins/rate-limit-advanced/schema.lua` | 已读 |
| `lib/algorithm.lua` | 已读，154 行（仓库版与容器内一致，11-11 07:31） |
| `lib/redis.lua` | 已读，129 行 |
| `lib/store.lua` | 已读，87 行 |
| `redis/token_bucket.lua` | 已读（与内嵌脚本重复） |
| `bench/common.sh` / `quota.sh` / `matrix.sh` | 已读 |
| `k6/quota.js` / `latency.js` | 已读 |
| `kong/kong.yml` | 已读 |

### 1.2 运行时核实（本次实测，非推断）

```
Kong 版本        : 3.6.1
worker 进程数    : 每节点 2 个
lua_shared_dict  : kong_rl 32m  ← 已注入 nginx-kong.conf:36，确认生效
插件挂载         : /usr/local/share/lua/5.1/kong/plugins/rate-limit-advanced (只读)
Lua 错误日志     : 三个节点均无 [error]
Redis key        : kong:rl:{rl:ip=172.20.0.1}（三节点共用同一 key，符合预期）
```

**这一条很重要**：本地库存确实走 shared dict，因此库存是**按节点**共享（2 个 worker 共用一份），不是每 worker 一份。最坏滞留量 = `节点数 × batch`，而非 `节点数 × worker 数 × batch`。

### 1.3 部署漂移（需先解决，否则后续测试不可信）

宿主机 `/home/tdohs/kong/kong-ratelimit/bench/common.sh` 仍是**旧版**：

```bash
46:  "limit_by":["ip"],"namespace":"rl",...   ← namespace 写死
```

仓库版本已改为每轮独立 namespace（第 5 个参数）。旧版会导致**每轮实验共享同一个桶**，上一轮的残留状态污染下一轮——这正是 116 的直接成因。

**结论：阶段一开始前，必须先把仓库版本同步到宿主机，否则任何测试结果都不可信。**

---

## 2. 模块审查表

| 模块 | 当前实现 | 存在问题 | 风险 | 建议方案 |
|---|---|---|---|---|
| **Token Bucket** | `rate = limit/window` 连续补充；`burst=0` 时取 `limit`；支持小数令牌；用 Redis `TIME()` 取时 | ① 时间回拨时把 `ts` 覆盖为更小的 `now`，回拨结束后同一段时间被**二次计费**，会多放令牌<br>② `X-RateLimit-Reset = now + window`，令牌桶没有"窗口重置"语义<br>③ `burst` 无上界，`burst > limit` 时突发不受控<br>④ `Retry-After` 无上限，`limit=1/window=3600` 时可达 3600s | **P0**(①)<br>P1(②③④) | ① `ts` 只前进不后退（`ts = max(ts, now)`）<br>② reset 改为"桶重新满的时间"或"下一个令牌可用时间"<br>③ 校验 `burst ∈ [1, K·limit]`<br>④ 明确上限并在文档说明 |
| **Redis Lua** | 单次 `EVAL` 内完成 HMGET→计算→HSET→PEXPIRE；失败时 `close()`；成功 `set_keepalive` | ① 返回值仅做 `tonumber` 兜底，未校验数组长度与 `granted ≤ want`<br>② 每次上传脚本全文（未用 `EVALSHA`）<br>③ 依赖 effects replication；若开启 `lua-replicate-commands yes` 会因 `TIME` 非确定性报错<br>④ 文档需明确"Lua 原子 ≠ 主从切换强一致" | P1 | ① 增加防御性校验，异常一律视为拒绝<br>② `EVALSHA` + `NOSCRIPT` 回退<br>③ 在 README 标注 Redis 配置前提<br>④ 见 `design.md` §4.6，表述已正确，需保持 |
| **本地库存** | `ngx.shared.kong_rl` 跨 worker 共享；`take()` 用 `incr(-1)`，负数回滚；`fill()` 用 `incr(+n)` + `expire` | ① shared dict 缺失时降级为 worker 私有表，**无任何启动告警**（`backend()` 从未被调用）<br>② `fill()` 两步非原子：`incr` 失败会静默丢令牌（少发），无日志<br>③ dict 满时 `incr` 返回 nil，同样静默<br>④ 库存 TTL 按当前 `window` 计算，配置变更后不重算 | P1/P2 | ① `init_worker` 里校验并 `log.warn`<br>②③ 失败时记 error 日志并计数<br>④ 与策略指纹一起解决 |
| **Batch** | 库存不足时向 Redis 领 `batch` 个，当前请求用 1 个，其余存入本地 | ① **Key 不含策略指纹**：配置变更后旧库存继续生效，实测 `116 > 100`<br>② `batch` 无上限，`batch > burst` 时单节点可一次抽干<br>③ 节点退出时未消费额度直接损失，无回收<br>④ `batch=1` 仍走本地库存分支，理论上可被残留库存"接走"，不满足"每请求必访问 Redis"的严格定义 | **P0**(①④)<br>P1(②③) | ① Key 加 `policy_version = hash(limit,window,burst,limit_by)`<br>② 校验 `batch ≤ burst`<br>③ 明确不回收，文档列出损失上界<br>④ `batch==1` 短路本地库存，直接 EVAL |
| **Key** | `kong:rl:{namespace:dim=val:...}`，用 `{}` 做 hash tag；header 值截断 256 | ① 无策略版本/指纹<br>② `path` 维度基数无治理（未归一化），易撑爆 Redis 内存<br>③ 多规则（一请求多桶）不支持<br>④ 维度缺失统一填 `-`，无法区分"没有 header"与"header 值为空" | **P0**(①)<br>P1(②③④) | ① 同上；见 `docs/key-design-phase-2.md`<br>② 路径归一化（`/user/123 → /user/:id`）<br>③ 明确列为"不支持"<br>④ 缺失值用独立哨兵并记录日志 |
| **故障处理** | `fault_tolerant=true` → fail-open + `X-RateLimit-Status: degraded`；`false` → 503 | ① **schema 默认 `true`，`kong.yml` 也是 `true`**，与新规范"默认 Fail-Closed"相反<br>② 429 路径**不打日志**，无法从日志区分"限流拒绝"与"Redis 故障"<br>③ fail-open 时不返回 `X-RateLimit-Limit`，响应头不一致<br>④ 配置错误返回 500，与 503 语义相近易混 | **P0**(①)<br>P1(②③④) | ① 默认改 `false`，文档与 kong.yml 同步<br>② 429 打 info 日志并带 key 与 limit<br>③ 统一响应头<br>④ 配置错误用 500 并附 `detail`（现状可接受，补充文档） |
| **动态配置** | DB-less 逐节点 `POST /config`；脚本参数每次从 `conf` 推导 | ① 无原子下发，多节点在更新窗口内可能短暂不一致<br>② `limit/window/burst` 变更不隔离旧桶与旧库存<br>③ `limit_by` 变更会隐式换 key，但旧 key 只能等 TTL 过期<br>④ 脚本对下发失败只 `warn` 不 `exit`，可能静默部分成功 | **P0**(②)<br>P1(①③④) | ① 文档写明窗口期语义<br>② 策略指纹<br>③ 文档写明<br>④ 测试脚本改为失败即中止 |
| **测试体系** | `quota.sh`（全局额度）、`matrix.sh`（batch×RPS）、k6 两脚本 | ① `k6/quota.js` 用 `(__VU-1) % 3` 选节点，配合 `shared-iterations`，**无法保证每节点恰好 150 次**（规范明确禁止随机分配替代）<br>② 无 per-node 统计<br>③ 无插件级指标（Redis 调用数 / 本地命中数 / 零授予次数），只能靠 Redis `INFO` 差值粗算<br>④ 无故障注入、无长稳压测、无节点故障测试<br>⑤ 宿主机脚本是旧版，与仓库不一致 | **P0**(①⑤)<br>P1(②③④) | ① 改用 `per-vu-iterations` 或按节点拆分 3 个 scenario，固定 VU 数与迭代数<br>② 输出按节点分组的统计<br>③ 插件内加计数器并通过响应头/日志暴露<br>④ 见阶段五、六<br>⑤ 先同步 |

---

## 3. 重点问题详述

### 3.1 P0-1｜Key 缺少策略指纹 → 额度被"继承"（已实测）

**现象**（2026-11-11 13:35，用户实测）：

```
配置：limit=100 window=3600 burst=0 batch=20
结果：allowed=116  limited=334  total=450   ← 超发 16
```

**排查证据**：

| 检查项 | 结果 | 说明 |
|---|---|---|
| 三节点插件配置 | 完全一致 `limit=100 window=3600 batch=20` | 排除配置不一致 |
| `failing open` 日志 | 0 次 | 排除降级放行 |
| Redis key 数量 | 1 个 | 排除 key 分裂 |
| Redis 桶状态 | `tokens=0.7402`，`ts` 距检查约 30s | 测试结束时桶正好被打空 |

**算术反推**：测试开始前桶已 15 小时未动，`refill` 被 `burst=100` 封顶 → 起始 100。测试期间按 `rate=100/3600=0.028/s` 补充约 0.74。**本轮 Redis 最多只能发出 100.74 个令牌，但放行了 116 个。**

多出的 16 个只能来自**测试开始前就已存在于本地库存中的令牌**——它们是上一轮 `limit=1000 / batch=auto` 时领取、未消费完的。

**根因**：Key = `kong:rl:{rl:ip=172.20.0.1}`，不含 `limit/window/burst/batch` 的任何信息。策略改变后，旧桶和旧库存仍然命中。

**这不是算法缺陷**（"放行量 ≤ 已发放量"这一不变量始终成立），而是**状态生命周期缺陷**：策略是"新"的，状态是"旧"的。

**影响**：
- 测试结果不可复现（同一配置两次跑出不同数字）
- 生产上缩配额时，已下发的库存会继续放行一段时间（文档已提，但未隔离）

**建议**：Key 中加入 `policy_version = short_hash(limit, window, burst, limit_by)`。策略一变即为新桶，旧桶按 TTL 自然淘汰。代价是配额变更瞬间"重新灌满"，需在文档中写明这一权衡，并考虑用 `namespace` 让运维显式控制。

### 3.2 P0-2｜默认 Fail-Open，与新规范相反

`schema.lua`：`fault_tolerant = { type = "boolean", default = true }`
`kong.yml`：`fault_tolerant: true`

当前行为：Redis 不可用 → 放行 + `X-RateLimit-Status: degraded`。
规范要求：默认 Fail-Closed（503）。

**影响**：Redis 故障期间限流完全失效，且这是"默认"配置，不是显式选择。
**建议**：默认改 `false`；`kong.yml` 同步；README 与 `design.md` 的取舍表同步更新（原文把 fail-open 写成"默认可用性优先"）。

### 3.3 P0-3｜IP 维度无条件信任 `X-Forwarded-For`

`algorithm.lua:22`：

```lua
return kong.client.get_forwarded_ip() or kong.client.get_remote_ip() or "unknown"
```

`get_forwarded_ip()` 会读取 XFF，而当前 Kong 未配置 `trusted_ips`。客户端只要每次请求换一个 `X-Forwarded-For`，就能无限绕过按 IP 的限流。

**影响**：以 IP 为维度的限流可被轻易绕过（安全风险）。
**建议**：明确两种模式之一——(a) 只用 `get_remote_ip()`；(b) 使用 forwarded IP 但必须配置 `trusted_ips` 并在文档中写明前提。

### 3.4 P0-4｜时间回拨会导致"重复计费时间"

`redis.lua:45-48,64`：

```lua
if now > ts then
  tokens = tokens + (now - ts) * rate
end
...
redis.call('HSET', key, 'tokens', tostring(tokens), 'ts', tostring(now))
```

若 Redis 宿主时钟回拨（NTP step），`now < ts`：
1. 本次不补充（正确）
2. **但 `ts` 被写成更小的 `now`**（错误）

等时钟回到原值后，`now - ts` 把**同一段时间又算了一遍**，凭空多出 `(ts_old - ts_new) × rate` 个令牌。

**影响**：罕见的超发路径，但违反"不重复发放"的基本要求。
**建议**：`ts` 单调递增，回拨时不更新（`if now > ts then ... ts = now end`），并记录一次告警。

### 3.5 P0-5｜测试无法证明"每节点固定请求数"

`k6/quota.js`：

```js
const node = NODES[(__VU - 1) % NODES.length];
...
executor: 'shared-iterations', vus: 30, iterations: 450
```

`shared-iterations` 把 450 次迭代**动态**分配给 30 个 VU，每个 VU 执行次数不等；而节点由 VU 编号取模决定。因此三个节点实际收到的请求数**不固定**，可能 148/151/151。

这与规范 §7.2"确保三个节点实际收到的请求量一致，不要用随机迭代分配结果代替每节点固定请求数"直接冲突。

**影响**：无法严格断言"每节点 150 次"，也就无法把"全局恰好 100"作为强证据（只能作为近似证据）。
**建议**：改成三个独立 scenario（每个固定 VU 数 + 固定迭代数），或 `per-vu-iterations` 且 VU 数按节点整除。

### 3.6 P1｜`batch=1` 未短路本地库存

当前 `algorithm.check()` 无条件先 `store.take(key)`。`batch=1` 时本地库存理论上恒空，但**如果存在上一轮残留**，请求会被本地库存接走，于是"每个请求都访问 Redis"这一基线定义不再成立。

**建议**：`batch == 1` 时跳过 `store.take/fill`，直接 EVAL。这同时让基线在代码层面可读。

### 3.7 P1｜`X-RateLimit-Reset` 语义不符

`reset = now + window`。令牌桶没有"窗口结束"概念，这个值对客户端没有指导意义（真到那时桶可能是满的，也可能不是）。

**建议**：改为"桶恢复到满所需时间"或"下一个令牌可用时间"，与 `Retry-After` 口径一致。

### 3.8 P1｜`remaining` 两条路径语义不一致

- fast path：返回**本地库存**剩余（不含全局）
- slow path：返回**Redis 全局**剩余

同一个客户端会看到数字在 19 → 980 之间跳变。功能上无害，但对外语义不清晰，容易被误读为 bug。

**建议**：统一为"本节点视角的可用量"或"全局剩余"，并在响应头命名上区分（如 `X-RateLimit-Remaining-Local`）。

---

## 4. 分级问题清单

### P0 — 必须修复（阻塞正确性/验收）

| 编号 | 问题 | 证据 |
|---|---|---|
| P0-1 | Key 无策略指纹，配置变更后旧桶/旧库存继续生效 | 实测 116 > 100 |
| P0-2 | 默认 Fail-Open，与规范要求的 Fail-Closed 相反 | `schema.lua` default=true |
| P0-3 | IP 维度无条件信任 XFF，未配置 trusted_ips | `algorithm.lua:22` |
| P0-4 | 时间回拨时 `ts` 被覆盖，导致重复计费时间 | `redis.lua:64` |
| P0-5 | 测试无法保证每节点固定请求数 | `k6/quota.js` |
| P0-6 | 宿主机脚本与仓库不一致（namespace 未参数化） | `bench/common.sh:46` |

### P1 — 重要（影响基线可信度或语义）

| 编号 | 问题 |
|---|---|
| P1-1 | `batch=1` 未短路本地库存，基线不纯 |
| P1-2 | `X-RateLimit-Reset` 不符合令牌桶语义 |
| P1-3 | `remaining` 在快慢路径语义不一致 |
| P1-4 | `header_name` 缺失只在运行时返回 500，schema 未校验 |
| P1-5 | Redis 返回值未做防御性校验（长度、`granted ≤ want`） |
| P1-6 | 无 per-node 统计与插件级指标（Redis 调用数/本地命中/零授予） |
| P1-7 | 429 路径无日志，故障与拒绝难以区分 |
| P1-8 | shared dict 降级为 worker 表时无任何告警（`backend()` 未被调用） |
| P1-9 | `Retry-After` 无上限（小 rate 时可到数千秒） |
| P1-10 | 未使用 `EVALSHA`，每次上传脚本文本 |

### P2 — 优化（性能/可维护性）

| 编号 | 问题 |
|---|---|
| P2-1 | `store.fill` 两步非原子（incr + expire），失败静默 |
| P2-2 | shared dict 满时无日志、无计数 |
| P2-3 | `redis/token_bucket.lua` 与内嵌脚本重复，双源易漂移 |
| P2-4 | `matrix.sh` 的 Redis ops 统计含其他命令与 k6 启动时间，偏粗 |
| P2-5 | 无 `.gitignore`，`bench/out/` 会进版本库 |
| P2-6 | README 表述"每 N 个请求访问一次 Redis"不准确（实际是"库存不足时领一批"，平均值才是 1/N） |
| P2-7 | 无 `init_worker`：不做启动自检、连接预热 |

---

## 5. 当前实现明确不支持的能力

必须写清楚，不能含糊：

1. **一个请求同时受多条独立规则约束**（Consumer 全局 + Consumer×Path + IP + Route 的"全满足才放行"）。
2. **多 Key 在单次 Lua 中的原子检查与统一扣减**（Redis Cluster 跨 Slot 限制）。
3. **固定的"窗口重置"语义**——本项目是令牌桶，没有整点重置。
4. **Redis 主从切换下的强一致性**：单主原子 ≠ 故障切换不丢写入。
5. **已发放额度的回收**（节点退出后本地库存不归还）。
6. **配置的原子下发**（DB-less 下逐节点 POST，存在短暂不一致窗口）。
7. **路径归一化 / 维度基数治理**。

---

## 6. 当前测试尚不能证明的能力

| 命题 | 现状 | 缺什么 |
|---|---|---|
| 高并发下不超发 | 只跑过 30 VU 一轮 | 10/50/100/200 并发矩阵、多轮重复 |
| batch=N 长期正确 | 只跑过单轮 450 请求 | 长稳压测、多窗口恢复、节点重启 |
| Redis 故障行为 | 仅读代码，未实测 | 停 Redis / 超时 / 认证失败 / 恢复 |
| 节点故障额度损失 | 未测 | 停节点、重启、继续压测 |
| 动态配置生效 | 手工 curl 验证过一次 | 系统性测试 + 一致性窗口观察 |
| shared dict 满了的行为 | 未测 | 灌满 32m 观察降级 |
| Redis Cluster 行为 | 未部署 | 集群环境 |
| 主从切换一致性边界 | 未测 | 主从 + 故障切换演练 |

---

## 7. 建议的改造顺序（对应后续阶段）

严格串行，每阶段单独验收：

| 阶段 | 内容 | 对应 P0 |
|---|---|---|
| 1（本报告） | 审查 | — |
| 2 | 严格基线：策略指纹、Fail-Closed 默认、时间回拨、batch=1 短路、测试脚本改造 | P0-1/2/4/5/6 |
| 3 | Key 设计与多规则评估（文档） | P0-1 的设计依据 |
| 4 | 维度验证、动态配置、429/503 语义 | P0-3、P1-4 |
| 5 | Batch 性能矩阵 + 长稳 | P1-6 |
| 6 | 异常与边界 | 全部 P1 |
| 7 | 最终性能与稳定性验收 | — |

**建议在阶段 2 之前先做一件事**：把仓库的 `bench/` 同步到宿主机（P0-6）。否则后续所有测试都会带着旧脚本的偏差。

---

## 8. 附：本次审查期间发现的部署事实

| 项 | 值 | 影响 |
|---|---|---|
| kong1 端口 | 8030/8031（非 8000） | Windows `iphlpsvc` 占用 8000 + WSL mirrored 网络 |
| Redis 宿主机端口 | 6380（容器内 6379） | 宿主机已有原生 redis-server 占用 6379 |
| 镜像来源 | 通过宿主代理 `127.0.0.1:7897` 拉取 | 未使用镜像站 |
| k6 | v2.3.0 | 脚本按 v0.4x 编写，实测兼容 |

以上三条端口/网络特殊性需写入最终文档的"环境说明"，否则他人复现会踩同样的坑。

---

**本阶段结束。未修改任何代码。等待确认后再进入阶段 2。**
