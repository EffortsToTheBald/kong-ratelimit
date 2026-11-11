# 4 天实施路线（每步都有可运行产物）

> 原则：**没有跑起来的东西不算学过**。每天结束时必须有一个能 `curl` 出结果的产物。
> 总预算 4 天，留半天缓冲。若只剩 2 天，砍掉第 3 天的矩阵，只做 `batch=1` 与 `batch=20` 两点对比。

---

## Day 0（半天）：Kong 插件机制 —— 目标：让一个插件"存在"

**要搞懂的三件事**

1. **插件是一个目录 + 两个文件**：`schema.lua`（配置模型，Kong 用它校验 Admin API 的输入并生成文档）
   和 `handler.lua`（返回一个表，表里有 `PRIORITY` 和各阶段函数）。目录名 = 插件名。
2. **阶段顺序**：`certificate → rewrite → access → response → header_filter → body_filter → log`。
   限流放在 `access`（在转发上游之前拦下，最省资源）。
3. **PDK 是唯一入口**：`kong.request.*` / `kong.response.*` / `kong.client.*` / `kong.log.*`。
   不要在插件里直接 `ngx.*` 处理业务（可以用 `ngx.shared` / `ngx.now` 这类基础设施）。

**必读**

- Kong 官方 *Plugin Development Guide*（`docs.konghq.com/gateway/latest/plugin-development/`）
- **Kong 源码 `kong/plugins/rate-limiting/`** 下的 `schema.lua`、`handler.lua`、`policies/` ——
  这是最高性价比的一步：官方实现就是你的对照组，你会看到它就是"固定窗口 + 每请求一次 Redis"。

**当天产物（Gate 1）**

```bash
docker compose up -d
curl -i http://localhost:8030/echo     # 返回头里有 X-RateLimit-*（此时可以都是假值）
```

能改 `kong.yml` 里的 `limit`，`POST /config` 后响应头数字跟着变，就算过关。

**坑**

- 插件目录必须挂到容器 `/usr/local/share/lua/5.1/kong/plugins/<name>`，且 `KONG_PLUGINS=bundled,<name>`。
- 改名不同步：`schema.lua` 的 `name` 必须和目录名一致，否则插件静默不加载。
- DB-less 模式下 Admin API 基本只读，改配置靠 `POST /config` 或 `kong reload`。

---

## Day 1（1 天）：Redis + Lua 原子限流 —— 目标：单节点语义 100% 正确

**要搞懂的三件事**

1. **Redis 单线程 + 脚本原子**：整个 `EVAL` 执行期间不会插入其他命令，所以"读-算-写"天然是一个事务，
   不需要 WATCH/MULTI。这是限流能放在 Redis 里的根本原因。
2. **时间必须取 `redis.call('TIME')`**，不能用 Kong 节点的 `ngx.now()`。多机时钟漂移 1 秒，
   令牌桶就会多算或少算一整秒的量。这是新手最常踩的坑。
3. **返回值的类型陷阱**：Redis 会把 Lua 的 number 截断成整数返回，浮点（比如剩余令牌 99.37）
   必须 `tostring()` 再返回，否则你永远看到 99。

**必读**

- Redis `EVAL` 文档（脚本原子性、`redis.call` 与 `redis.pcall`）
- `lua-resty-redis`（`connect` / `set_timeouts` / `set_keepalive`；**忘了 keepalive 会在高并发下耗尽端口**）

**当天产物（Gate 2）**

```bash
# 先脱离 Kong，在 redis-cli 里裸跑脚本
redis-cli --eval redis/token_bucket.lua rl:test , 1.67 100 1 120000
```

连续执行 101 次，前 100 次返回 `{1,...}`，第 101 次返回 `{0,...}`，并且第三次参数里的 wait 是正数。

**坑**

- `HMGET` 对不存在的字段返回 `false` 而不是 `nil`，`tonumber(false)` 才是 `nil`——别写 `if d[1] == nil`。
- `PEXPIRE` 用毫秒，`EXPIRE` 用秒，混用会让 key 立刻过期或永不过期。
- 脚本里不要用 `math.random`（结果不确定，主从复制会不一致）。

---

## Day 1.5（半天）：接进 Kong —— 目标：单节点 429 正确

把 `algorithm.lua` 接上，先只跑 `batch=1`（每次向 Redis 领 1 个）。

**当天产物（Gate 3）**

```bash
# limit=5, window=60
for i in $(seq 1 7); do curl -s -o /dev/null -w "%{http_code} " localhost:8030/echo; done
# 期望：200 200 200 200 200 429 429
```

且第 6 个响应带 `Retry-After`，值 ≈ 60/5 = 12 秒量级。

---

## Day 2（1 天）：分布式 —— 目标：证明"三个节点一个池子"

**顺序很重要**：1 节点 → 起第 2 个 → 起第 3 个。每次都先确认"配额是共享的"，再往下走。

**当天产物（Gate 4）**

`limit=100, window=3600, batch=1`，三个节点各打 150 次（共 450）：

```
通过总数 == 100（严格等于）
```

然后把 `batch` 改成 20，重跑：

```
通过总数 ∈ [40, 100]      # 少发，绝不超发
```

**这一步就是整份作业的核心论点**：同一份代码，一个参数，从"精确"滑到"快"。

**坑**

- 三个 Kong 容器各自有独立的 declarative config，改配置要 `POST /config` 打到**三个**节点，
  只打一个会出现"节点间配置不一致"的诡异现象。
- 别用外部负载均衡，客户端轮询三个端口最直观；上了 LB 你反而说不清请求落在哪。

---

## Day 2.5（半天）：性能矩阵 —— 目标：一张有结论的表

**实验必须控制变量**：只变 `batch`，其他全固定；每组至少 30s；先跑基线（不装插件）。

**当天产物（Gate 5）**

`bench/results.md` 里有三条曲线（或一张表）：

| batch | p99 | 通过数 | Redis ops/s |
|---|---|---|---|
| 基线（无插件） | ? | 全过 | 0 |
| 1 | ? | 100 | ~RPS |
| 20 | ? | ~95 | RPS/20 |

**结论必须写成一句话**，例如：
> 「batch=20 时 p99 只比基线高 0.2ms，Redis 负载降到 1/20，代价是最多少发 6% 的配额。
> 在小配额（limit<100）场景下这个代价不可接受，所以 auto 会退化成 batch=1。」

---

## Day 3（1 天）：文档 —— 目标：让面试官 10 分钟看懂你的取舍

按 `docs/design.md` 的骨架填，重点不是功能清单，而是：

1. **架构图**（加分项，必须有）
2. **误差上界推导**（证明你懂自己方案的边界，而不是"跑通了"）
3. **取舍表**：做了什么 / 简化了什么 / 为什么
4. **生产化差距清单**：如果上线还差什么
5. **和官方插件的对比**：说明你不是重复造轮子，而是知道轮子差在哪

---

## 时间不够时的裁剪顺序

砍到 2 天时，按这个顺序丢：

1. 丢 `docs/bench.md` 的完整矩阵 → 只保留 `batch=1` vs `batch=20` 两组
2. 丢 `limit_by` 的多维组合 → 只留 `ip`
3. 丢故障降级（fail-open）→ 但**不能丢**误差分析，那是全篇最有价值的部分
