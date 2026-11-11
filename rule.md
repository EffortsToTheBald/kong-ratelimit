# Kong Advanced Rate Limiting
# SDD 开发规格与分阶段优化实施文档

**项目名称：** rate-limit-advanced  
**文档类型：** Software Design Specification / SDD  
**目标：** 基于现有 Kong 自定义限流插件，逐步完善分布式令牌桶、全局配额一致性、多维限流 Key、本地批量令牌租赁及性能优化。  
**开发方式：** DeepSeek 辅助开发，分阶段修改、测试、验收。  
**核心原则：** 保留现有架构，优先修复正确性问题，再进行性能优化。

---

# 一、项目背景与目标

## 1.1 项目背景

基于开源 Kong Gateway 开发一个自定义限流插件 `rate-limit-advanced`。

项目需要解决的问题：

1. 多个 Kong 节点如何共享同一份全局限流配额。
2. 如何保证并发请求下令牌扣减的原子性。
3. 如何支持 IP、Consumer、Path、Method、Header、Route、Service 等多个维度的限流。
4. 如何降低每个请求访问 Redis 的开销。
5. 如何在保证全局限流正确性的前提下，通过本地令牌库存提高吞吐量。
6. Redis 不可用时如何保证限流安全性。
7. 如何验证多节点部署下的配额正确性和性能。

## 1.2 第一版目标架构

采用：

- 3 个 Kong Gateway 节点。
- 1 个 Redis 实例。
- Redis Lua 实现全局原子令牌桶。
- Kong 节点使用 `lua_shared_dict` 保存本地令牌库存。
- 使用 batch 机制批量从 Redis 领取令牌。
- 插件在 Kong Access 阶段完成限流判断。

整体架构：

```text
                  Client
                    |
                    v
              Load Balancer
                    |
          +---------+---------+
          |         |         |
          v         v         v
       Kong1     Kong2     Kong3
          |         |         |
          |         |         |
          v         v         v
       Shared    Shared    Shared
       Dict      Dict      Dict
          |         |         |
          +---------+---------+
                    |
             Redis Lua Script
                    |
                    v
             Global Token Bucket
```

说明：

- 每个 Kong 节点拥有自己的 `lua_shared_dict`。
- 同一个 Kong 节点内的 Nginx Worker 共享该节点的 shared dict。
- 不同 Kong 节点之间不共享本地库存。
- Redis 是全局配额的唯一权威数据源。
- 本地库存只是 Redis 已经授权给节点的令牌租赁额度。

**重要：三个 Kong 节点的 shared dict 并不是同一份数据。**

---

# 二、核心限流算法：Token Bucket

## 2.1 为什么选择令牌桶

令牌桶能够同时支持：

- 平均速率限制。
- 短时间突发流量。
- 分布式并发扣减。
- 本地批量领取令牌。

相比简单的固定窗口计数器，令牌桶能够更加平滑地控制请求速率。

## 2.2 核心参数

配置：

```json
{
  "limit": 100,
  "window": 3600,
  "burst": 100,
  "batch": 20
}
```

参数含义：

| 参数 | 含义 |
|---|---|
| limit | 令牌桶的基础配额 |
| window | 令牌补充周期，单位秒 |
| burst | 令牌桶最大容量 |
| batch | Kong 节点每次从 Redis 领取的令牌数量 |

注意：

`window` 不是固定窗口计数器的窗口边界。

当前方案是令牌桶模型：

```text
rate = limit / window
```

例如：

```text
limit = 100
window = 3600

rate = 100 / 3600
     = 0.02778 tokens/s
```

表示每秒补充约 0.02778 个令牌。

也就是平均每小时补充 100 个令牌。

如果：

```text
burst = 100
```

那么令牌桶最大容量是 100。

系统启动后首次访问时，桶初始化为满桶。

因此：

- 初始最多允许 100 个请求。
- 后续按照 rate 逐渐补充令牌。
- 令牌数量永远不能超过 burst。

这是一种持续补充的令牌桶，而不是每小时整点重置 100 次。

## 2.3 令牌桶计算公式

假设：

- `tokens`：上一次剩余令牌数量。
- `now`：当前 Redis 时间。
- `ts`：上一次计算时间。
- `rate`：每秒补充令牌数。
- `burst`：桶容量。

补充令牌：

```text
elapsed = now - ts

tokens = min(
    burst,
    tokens + elapsed * rate
)
```

消费令牌：

```text
if tokens >= want:
    granted = want
else:
    granted = floor(tokens)

tokens = tokens - granted
```

注意：当前实现允许部分领取。

例如：

```text
want = 20
tokens = 13.8

granted = 13
```

计算等待时间：

```text
if tokens < 1:
    wait = (1 - tokens) / rate
```

Redis Lua 必须保证：

1. 读取令牌数量。
2. 计算补充令牌。
3. 扣减令牌。
4. 更新状态。
5. 更新 TTL。

以上操作在同一个 Lua 脚本中原子执行。

## 2.4 Redis 时间

使用：

```lua
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
```

不使用 Kong 节点本地时间作为全局桶的计算依据。

原因：

多个 Kong 节点可能存在时钟偏差。

由 Redis 提供统一时间，可以避免不同网关节点分别计算补充令牌造成的时间漂移。

另外，需要检查时间回拨：

```text
if now > ts:
    补充令牌
else:
    不补充令牌
```

不能因为时间回拨而产生额外令牌。

---

# 三、Redis Key 设计

这是项目的重要设计，需要保留现有约定。

## 3.1 Key 格式

采用：

```text
kong:rl:{rl:ip=10.0.0.7:path=/echo}
```

结构：

```text
kong:rl:
    {
        rl:
        ip=10.0.0.7:
        path=/echo
    }
```

其中：

- `kong:rl:` 是 Redis Key Prefix。
- `{}` 是 Redis Cluster Hash Tag。
- `rl:` 是限流规则命名空间。
- `ip=...` 是 IP 维度。
- `path=...` 是 Path 维度。

## 3.2 为什么使用 Hash Tag

Redis Cluster 根据 Key 计算 CRC16，然后映射到 16384 个 Hash Slot。

Redis Cluster 支持 Hash Tag：

```text
prefix:{hash-tag}:suffix
```

计算 Slot 时只使用 `{}` 中的内容。

例如：

```text
kong:rl:{rl:ip=10.0.0.7:path=/echo}
kong:rl:{rl:ip=10.0.0.7:path=/echo}:metadata
kong:rl:{rl:ip=10.0.0.7:path=/echo}:stats
```

这几个 Key 会落在同一个 Slot。

为未来扩展多个相关 Redis Key、Lua 多 Key 操作以及相关状态预留能力。

**重要约束：**

1. 完整的限流规则标识必须放入 Hash Tag。
2. 相同规则、相同维度值必须生成相同的 Key。
3. 不同规则不能意外共享同一个桶。
4. 多维度必须共同参与 Key 的计算。
5. 维度顺序必须稳定，避免相同逻辑规则生成不同 Key。
6. 不要将不同维度拆成多个独立 Key，除非后续明确实现多规则联合判定。

## 3.3 支持的维度

| 维度 | 取值 |
|---|---|
| consumer | Consumer ID |
| ip | Forwarded IP / Remote IP |
| path | 请求 Path |
| method | HTTP Method |
| header | 指定 Header |
| route | Route ID |
| service | Service ID |

例如：

配置：

```json
{
  "limit_by": ["ip", "path"]
}
```

请求：

```text
GET /echo
IP = 10.0.0.7
```

生成：

```text
kong:rl:{rl:ip=10.0.0.7:path=/echo}
```

如果只配置：

```json
{
  "limit_by": ["ip"]
}
```

生成：

```text
kong:rl:{rl:ip=10.0.0.7}
```

## 3.4 Key 设计需要优化的地方

后续需要重点检查：

- 维度顺序是否固定。
- Header 是否需要限制长度。
- 特殊字符是否需要转义。
- 是否存在不同维度拼接后产生歧义的可能。
- 是否需要规则 ID 作为独立标识。
- namespace 是否可以区分不同限流策略。

不要在第一阶段随意修改 Key 格式。

先编写单元测试，确认现有规则生成结果，再决定是否优化。

---

# 四、分布式令牌管理架构

## 4.1 Redis 全局桶

Redis 保存全局状态：

```text
Key:
kong:rl:{rl:ip=10.0.0.7:path=/echo}

Hash:
tokens
ts
```

示例：

```text
tokens = 60
ts = 1794380834.8841
```

Redis 负责：

- 全局令牌数量。
- 令牌补充。
- 原子扣减。
- 批量令牌授权。
- 等待时间计算。

Redis 是唯一权威状态。

## 4.2 Kong 本地库存

每个 Kong 节点有自己的本地库存。

例如：

```text
Kong1:
    local_tokens = 20

Kong2:
    local_tokens = 20

Kong3:
    local_tokens = 20
```

实际情况是库存由各节点自己的 `lua_shared_dict` 管理。

本地库存用于减少 Redis 网络请求。

请求流程：

```text
Request
   |
   v
store.take(key)
   |
   +---- 本地有令牌
   |          |
   |          v
   |       扣减 1
   |          |
   |          v
   |       放行请求
   |
   +---- 本地没有令牌
              |
              v
        Redis Lua 申请
              |
              v
        获得 granted
              |
              +---- granted = 0
              |          |
              |          v
              |         429
              |
              +---- granted > 0
                         |
                         v
                 当前请求消耗 1
                         |
                         v
                 剩余令牌放入本地
                         |
                         v
                       放行
```

## 4.3 batch 机制

batch 表示每次从 Redis 申请多少令牌。

例如：

```text
batch = 20
```

当本地库存为空时，向 Redis 申请 20 个令牌。

Redis 原子扣减 20 个令牌。

当前请求使用其中 1 个。

剩余 19 个存入本地库存。

下一次请求可以直接使用本地库存。

因此：

```text
batch = 1
```

每个请求都需要向 Redis 申请令牌。

```text
batch = 20
```

一个节点成功申请后，可以连续处理后续本地库存请求。

## 4.4 batch=1 与 batch=N 的区别

| 模式 | 特点 | 代价 |
|---|---|---|
| batch=1 | 每次请求都经过 Redis 原子判定 | Redis 请求量较大 |
| batch=N | 本地预留一批令牌 | 可能产生令牌滞留 |

batch=1 是全局严格配额模式。

batch=N 是分布式令牌租赁模式。

必须明确：

**batch=N 不代表每个节点都可以独立获得 N 个额外配额。**

所有节点申请的令牌仍然由同一个 Redis 全局桶控制。

## 4.5 本地令牌滞留问题

假设：

```text
limit = 100
batch = 20
Kong 节点 = 3
```

如果：

```text
Kong1 申请 20
Kong2 申请 20
Kong3 申请 20
```

三个节点已经从 Redis 预留 60 个令牌。

如果后续 Kong1 收到大量请求，而 Kong2、Kong3 没有继续收到请求，那么 Kong2、Kong3 的本地令牌可能一直没有被消费。

这就是令牌滞留。

它不会造成超发，但会降低配额利用率。

在理想条件下，假设每个节点最多遗留 batch-1 个令牌，则：

```text
理论最小放行量：

allowed >= limit - N * (batch - 1)
```

为了保守和兼容原测试脚本，可以使用：

```text
allowed >= max(0, limit - N * batch)
```

其中 N 是 Kong 节点数。

注意：这个范围是基于本地库存管理正确、每个节点只存在一个共享库存池、测试期间没有明显令牌补充等条件的工程验收参考，不是无条件数学保证。

---

# 五、batch 自动计算策略

当前实现：

```lua
local k = math.floor(conf.limit / 50)

if k < 1 then
    k = 1
end

if k > 50 then
    k = 50
end

return k
```

公式：

```text
batch = clamp(floor(limit / 50), 1, 50)
```

示例：

| limit | auto batch |
|---:|---:|
| 10 | 1 |
| 50 | 1 |
| 100 | 2 |
| 500 | 10 |
| 1000 | 20 |
| 5000 | 50 |

目的：

- 小配额避免过多令牌滞留。
- 大配额减少 Redis 请求。
- 控制最大批量领取数量。

后续需要验证这个策略是否合理。

暂时不要直接修改默认算法。

应通过压测比较：

- batch=1
- batch=5
- batch=10
- batch=20
- batch=50
- batch=auto

记录配额利用率、Redis 请求次数、延迟和吞吐量。

---

# 六、Redis TTL 设计

当前算法：

```lua
local ttl_s = math.max(
    1,
    math.floor(conf.window * 2)
)

local ttl_ms = ttl_s * 1000
```

例如：

```text
window = 3600

TTL = 7200 seconds
```

即 2 小时。

目的：

限流规则在长时间没有请求后，可以自动清理 Redis 状态。

TTL 不是令牌补充周期。

`window` 决定补充速率。

`TTL` 决定 Redis Key 多久没有访问后过期。

需要检查：

1. TTL 是否可能在本地库存仍然有效时提前过期。
2. 多个 Kong 节点对同一 Key 的 TTL 是否一致。
3. Redis Key 过期后重新创建是否会造成新的满桶。
4. 本地库存与 Redis Key 过期是否存在生命周期不一致。

特别需要注意：

如果 Redis Key 已经过期，但 Kong 本地仍然持有之前租赁的令牌，系统可能出现旧库存与新桶并存的问题。

需要在后续版本中通过租赁有效期、规则版本或其他机制解决这一生命周期问题。

不能只依赖 Redis TTL 就认为本地库存一定同步过期。

---

# 七、失败策略：Fail-Closed

## 7.1 为什么选择 Fail-Closed

本项目第一版选择：

**Redis 不可用时拒绝请求，返回 503。**

不允许 Redis 故障时自动放行。

原因：

如果 Redis 不可用，而 Kong 选择放行，那么限流功能将失效。

对于需要保证全局配额的 API，这可能造成严重的流量失控。

## 7.2 两种策略对比

| 策略 | Redis 不可用时 | 风险 |
|---|---|---|
| Fail-Open | 放行请求 | 可能突破限流配额 |
| Fail-Closed | 返回 503 | 业务可用性下降 |

当前配置：

```json
{
  "fault_tolerant": false
}
```

对应代码：

```lua
if not decision then
    if conf.fault_tolerant then
        return
    end

    return kong.response.exit(503, {
        message = "rate limiter unavailable"
    })
end
```

## 7.3 必须覆盖的故障

- Redis 连接失败。
- Redis 认证失败。
- Redis SELECT 失败。
- Redis EVAL 执行失败。
- Redis 超时。
- Redis 返回异常数据。
- Lua 脚本运行错误。

全部需要验证 Fail-Closed。

注意：

不能将正常的限流拒绝 429 与 Redis 故障 503 混淆。

---

# 八、HTTP 响应设计

## 8.1 正常放行

```http
HTTP/1.1 200 OK

X-RateLimit-Limit: 100
X-RateLimit-Remaining: 99
X-RateLimit-Reset: 1794384434
```

## 8.2 超出配额

```http
HTTP/1.1 429 Too Many Requests

Content-Type: application/json
Retry-After: 36
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 0
```

响应体：

```json
{
  "message": "API rate limit exceeded",
  "limit": 100,
  "window": 3600,
  "retry_after": 36
}
```

## 8.3 Redis 不可用

```http
HTTP/1.1 503 Service Unavailable
```

响应体：

```json
{
  "message": "rate limiter unavailable"
}
```

## 8.4 响应头要求

需要验证：

- 429 必须返回 Retry-After。
- 503 不应伪装成正常限流。
- hide_client_headers=true 时不暴露限流响应头。
- reset 的含义必须与实际令牌桶算法一致。

当前 `reset = now + window` 是近似展示值，不代表令牌桶在 reset 时间整桶重置。

建议后续明确响应头的语义，避免将令牌桶错误描述为固定窗口。

---

# 九、现有代码审查与待修复问题

以下是当前实现需要重点检查的地方。

## 9.1 redis.lua

当前模块：

```text
lib/redis.lua
```

负责：

- Redis 连接。
- 认证。
- 数据库选择。
- Lua 执行。
- Keepalive 连接池。

必须检查：

1. 连接失败是否正确处理。
2. AUTH 失败是否关闭连接。
3. SELECT 失败是否关闭连接。
4. EVAL 失败是否关闭连接。
5. 成功执行后是否正确放回连接池。
6. keepalive 失败时是否正确处理。
7. Redis 返回值是否合法。
8. rate、burst、want、ttl 是否完成参数校验。

特别注意：

Redis 客户端连接池需要与 Kong/OpenResty 的运行模型兼容，不能在请求间共享一个未正确管理的 Redis 连接对象。

## 9.2 algorithm.lua

当前模块：

```text
lib/algorithm.lua
```

负责：

- 构建限流 Key。
- 计算 batch。
- 计算 rate 和 burst。
- 本地库存消费。
- Redis 批量领取。
- 最终限流决策。

需要重点检查以下逻辑。

### 问题 A：Redis 返回 nil 时的错误处理

当前调试代码存在：

```lua
local granted, err = redis_mod.grant(...)

kong.log.notice(
    "[RL-DEBUG] redis_grant key=", key,
    " granted=", granted.granted,
    " tokens=", granted.tokens
)

if not granted then
    return nil, err
end
```

这里存在明显问题。

如果 Redis 调用失败：

```lua
granted = nil
```

那么：

```lua
granted.granted
```

会直接触发 Lua 异常。

必须先判断：

```lua
local granted, err = redis_mod.grant(...)

if not granted then
    kong.log.err(
        "rate-limit-advanced: redis grant failed: ",
        tostring(err)
    )

    return nil, err
end
```

然后再记录成功结果。

### 问题 B：本地库存补充失败

当前：

```lua
if granted.granted > 1 then
    store.fill(
        key,
        granted.granted - 1,
        ttl_s
    )
end
```

必须检查：

- store.fill 是否成功。
- 是否可能因 shared dict 容量不足而失败。
- 是否存在并发覆盖库存。
- 是否可能造成已从 Redis 领取的令牌丢失。
- 是否有正确的错误日志和指标。

不能忽略本地库存写入失败。

如果库存无法保存，必须明确如何处理已经领取的令牌，保证不产生超发。

### 问题 C：本地库存并发扣减

必须检查：

```lua
store.take(key)
```

是否具备原子性。

不能采用：

```text
读取库存
判断库存
库存减一
写回库存
```

这种不具备原子性的分离操作。

多个 Worker 并发访问时可能重复消费同一个令牌。

应使用适合 OpenResty shared dict 的原子操作实现。

### 问题 D：本地库存与 Redis 状态一致性

需要明确：

- Redis 负责全局授权。
- 本地库存负责已授权令牌的消费。
- 本地库存不能凭空产生令牌。
- 本地库存过期不能导致超发。
- Redis Key 过期不能让旧本地库存继续无限有效。

这一部分是后续最重要的架构优化方向。

## 9.3 store.lua

这是必须重点审查的模块。

要求 DeepSeek 先读取完整实现，不要假设它已经正确。

需要验证：

1. 使用的 shared dict 名称是否正确。
2. 多 Worker 是否共享同一份库存。
3. 多个请求同时 take 是否安全。
4. fill 是否存在并发覆盖。
5. 库存是否有 TTL。
6. TTL 是否与 Redis 租赁生命周期协调。
7. shared dict 空间不足时如何处理。
8. 是否存在库存泄漏。

当前 Kong 配置已经验证：

```nginx
lua_shared_dict kong_rl 32m;
```

三个节点均存在该配置。

因此不能再简单将问题归因于 shared dict 未配置。

必须进一步检查实际 `store.lua` 的操作语义。

---

# 十、之前压测发现的问题与结论

这一部分非常重要，DeepSeek 必须参考真实测试结果。

## 10.1 测试环境

```text
Kong 节点：3
Redis：1
limit：100
window：3600
burst：100
请求总量：450
每节点计划请求：150
VUS：30
```

测试入口：

```text
kong1: localhost:8030
kong2: localhost:8010
kong3: localhost:8020
```

## 10.2 batch=1 测试

测试命令：

```bash
./bench/quota.sh -l 100 -b 1 -p 150
```

测试结果：

```text
allowed = 100
limited = 350
other = 0
total = 450
```

不同测试轮次中，三个节点的放行量不同。

但全局始终：

```text
allowed = 100
```

日志统计：

```text
Redis 申请次数：450
本地库存命中次数：0
```

结论：

- batch=1 时每个请求都访问 Redis。
- Redis Lua 原子扣减有效。
- 三个 Kong 节点共享全局配额。
- 全局配额没有超发。

这是当前最重要的正确性基线。

## 10.3 batch=20 测试

测试命令：

```bash
./bench/quota.sh -l 100 -b 20 -p 150
```

出现过以下结果：

第一次：

```text
allowed = 10
limited = 440
```

第二次：

```text
allowed = 100
limited = 350
```

第三次：

```text
allowed = 82
limited = 368
```

第四次：

```text
allowed = 45
limited = 405
```

后续也出现：

```text
allowed = 20
limited = 430
```

这说明 batch=20 的配额利用率存在明显波动。

## 10.4 发现的流量分布问题

某次测试：

```text
========== 全局统计 ==========

allowed=20
limited=430
other=0

========== 节点请求分布 ==========

kong1:
requests=18
allowed=10
limited=8

kong2:
requests=17
allowed=10
limited=7

kong3:
requests=415
allowed=0
limited=415
```

另一次测试：

```text
kong1:
requests=150
allowed=100
limited=50

kong2:
requests=150
allowed=0
limited=150

kong3:
requests=150
allowed=0
limited=150
```

另一次：

```text
kong1:
requests=150
allowed=0
limited=150

kong2:
requests=150
allowed=100
limited=50

kong3:
requests=150
allowed=0
limited=150
```

这些结果表明：

**批量领取令牌后，令牌可能集中滞留在部分 Kong 节点，其他节点即使持续收到请求，也无法使用其他节点的本地库存。**

需要重点分析：

- 请求如何分配给不同 Kong 节点。
- Kong 节点内部 Worker 如何共享库存。
- 一个节点是否存在多个独立库存池。
- 是否出现 Redis 已经授权，但本地库存无法被其他 Worker 使用的情况。
- 本地库存是否存在并发覆盖。
- 是否有节点成功领取令牌但后续流量不足。

不能简单根据某个节点请求数少、Redis 申请次数多，就直接判断是某个确定的 Bug。

必须使用同一轮测试的完整日志和请求分布进行关联分析。

另外，之前使用：

```bash
docker compose logs --since=5m
```

收集过日志。

这种方式可能包含之前多轮测试的日志。

后续测试必须确保日志只对应当前这一轮。

## 10.5 需要修正的理论判断

当前测试脚本采用：

```text
shared-iterations
```

每个 VU 根据：

```javascript
const node = NODES[(__VU - 1) % NODES.length];
```

固定使用一个节点。

因此：

不能把 `shared-iterations` 理解成每个节点严格均匀分配 150 次请求。

后续必须提供两种独立测试：

1. 三节点均匀分配测试。
2. 三节点非均匀分配测试。

均匀测试用于验证基本正确性。

非均匀测试用于验证批量令牌滞留和利用率。

两种结果不能混为一谈。

---

# 十一、SDD 分阶段开发计划

要求 DeepSeek 严格按照以下顺序执行。

**禁止一次性重写整个插件。**

每个阶段必须完成：

1. 阅读相关源代码。
2. 分析现有实现。
3. 列出发现的问题。
4. 提出最小修改方案。
5. 修改代码。
6. 执行测试。
7. 生成测试报告。
8. 等待人工验收后进入下一阶段。

## Phase 0：代码基线与架构审查

目标：

先完整理解现有代码，不修改业务逻辑。

需要阅读：

```text
rate-limit-advanced/
    handler.lua
    schema.lua
    lib/
        algorithm.lua
        redis.lua
        store.lua

bench/
    quota.sh
    common.sh

k6/
    quota.js
```

输出：

```text
reports/phase-0-baseline.md
```

报告内容：

- 当前模块职责。
- 当前请求调用链。
- Redis Lua 执行过程。
- 本地库存操作过程。
- Key 生成规则。
- batch 机制。
- 当前已知问题。
- 风险清单。

验收：

必须能够完整解释一次请求从 Kong Access 到最终 200、429 或 503 的流程。

## Phase 1：核心正确性修复

目标：

先保证算法正确。

检查和修复：

1. Redis 返回 nil 时的异常。
2. Redis 错误处理。
3. Lua 令牌桶时间计算。
4. 时间回拨。
5. burst 上限。
6. 部分领取逻辑。
7. 本地库存原子扣减。
8. 本地库存写入失败。
9. TTL 处理。
10. Fail-Closed。

测试：

### 测试 A：基础令牌桶

```text
limit=100
window=3600
burst=100
batch=1
```

预期：

初始 100 个请求放行，后续没有足够令牌时返回 429。

### 测试 B：并发正确性

多个 Kong 节点并发访问同一个 Key。

预期：

```text
allowed = 100
limited = 350
other = 0
```

### 测试 C：Redis 故障

停止 Redis：

```bash
docker compose stop redis
```

发送请求。

预期：

```text
HTTP 503
```

不能返回 200。

恢复：

```bash
docker compose start redis
```

### 测试 D：令牌补充

等待一段时间后重新请求。

检查补充数量是否符合：

```text
tokens += elapsed * rate
```

并且不能超过 burst。

输出：

```text
reports/phase-1-correctness.md
```

## Phase 2：Key 与多维规则

目标：

保证多维限流规则稳定且不会发生 Key 冲突。

测试维度：

```text
ip
consumer
path
method
header
route
service
```

测试组合：

```json
{
  "limit_by": ["ip"]
}
```

```json
{
  "limit_by": ["ip", "path"]
}
```

```json
{
  "limit_by": ["consumer", "path", "method"]
}
```

验证：

1. 相同维度值生成相同 Key。
2. 不同维度值生成不同 Key。
3. 多维组合不会错误共享桶。
4. namespace 可以区分规则。
5. Redis Hash Tag 格式正确。
6. 同一规则的关联 Key 可以落在同一个 Redis Cluster Slot。
7. 特殊字符不会产生 Key 歧义。

必须保留：

```text
kong:rl:{rl:ip=10.0.0.7:path=/echo}
```

作为基础格式。

输出：

```text
reports/phase-2-key-design.md
```

## Phase 3：插件行为与错误处理

目标：

确保 Kong 插件行为符合预期。

测试：

- 正常请求 200。
- 超限请求 429。
- Retry-After 正确。
- Redis 故障返回 503。
- Header 隐藏配置有效。
- Consumer 维度有效。
- Path 维度有效。
- Route / Service 维度有效。
- 配置缺失时返回合理错误。
- 配置更新后行为正确。

检查：

```text
handler.lua
schema.lua
```

尤其检查：

```lua
PRIORITY = 1002
```

认证与限流插件的执行顺序必须与 Consumer 维度设计相匹配。

如果需要 Consumer ID 限流，应保证认证插件先执行。

输出：

```text
reports/phase-3-plugin-behavior.md
```

## Phase 4：Shared Dict 与 Batch 优化

目标：

在正确性稳定后优化性能。

首先检查：

```text
lua_shared_dict kong_rl 32m;
```

当前已经验证三个节点均存在：

```nginx
lua_shared_dict kong_rl 32m;
```

但必须继续验证实际 store.lua 是否真正使用该字典。

重点：

1. 所有 Worker 是否使用同一个节点级库存池。
2. 是否存在多个独立库存。
3. take 是否原子。
4. fill 是否原子或具备正确并发保护。
5. 本地库存是否存在滞留。
6. 库存 TTL 是否合理。
7. 规则变化后是否清理旧库存。

### 测试矩阵

```text
limit=100
window=3600
burst=100
```

依次执行：

```bash
./bench/quota.sh -l 100 -b 1 -p 150
./bench/quota.sh -l 100 -b 5 -p 150
./bench/quota.sh -l 100 -b 10 -p 150
./bench/quota.sh -l 100 -b 20 -p 150
./bench/quota.sh -l 100 -b 50 -p 150
```

每组至少重复 10 次。

统计：

- allowed。
- limited。
- other。
- 配额利用率。
- Redis grant 次数。
- local_hit 次数。
- local_fill 次数。
- 各节点请求数。
- 各节点放行数。
- 各节点库存滞留量。

重点优化：

**不能为了减少 Redis 请求而引入超发风险。**

同时要解决批量领取造成的本地令牌滞留。

可以研究：

- 本地库存租赁生命周期。
- 空闲库存回收。
- batch 自适应调整。
- 不同节点流量不均衡时的库存策略。

但是任何库存回收方案都必须考虑并发安全，不能直接把本地库存重新加回 Redis 而没有防重复归还机制。

输出：

```text
reports/phase-4-batch-performance.md
```

## Phase 5：工程化测试与最终验收

目标：

验证系统在实际多节点部署下的可靠性。

测试场景：

### 场景 1：正常流量

```text
3 Kong
1 Redis
limit=100
batch=1
```

要求：

全局严格不超过 100。

### 场景 2：批量领取

```text
3 Kong
1 Redis
limit=100
batch=20
```

要求：

全局不能超发，统计利用率和库存滞留。

### 场景 3：流量不均衡

例如：

```text
Kong1: 10%
Kong2: 10%
Kong3: 80%
```

要求：

验证令牌滞留情况。

### 场景 4：Redis 故障

要求：

Fail-Closed。

### 场景 5：Kong 节点重启

测试：

- 一个节点重启。
- 多个节点重启。
- 节点本地库存丢失。
- 其他节点继续处理请求。

要求：

不能出现全局超发。

### 场景 6：持续令牌补充

持续运行一段时间。

验证：

- rate 正确。
- burst 正确。
- TTL 正确。
- 没有累计超发。

### 场景 7：配置变更

修改：

- limit。
- window。
- burst。
- batch。
- limit_by。

检查旧库存是否可能污染新规则。

输出：

```text
reports/final-acceptance.md
```

---

# 十二、压测与日志要求

## 12.1 每轮测试必须隔离

每次测试前：

```bash
docker compose restart kong1 kong2 kong3
```

等待 Kong 完全启动。

然后：

```bash
docker compose exec redis redis-cli FLUSHDB
```

确认 Redis 已清空。

再执行压测。

注意：

`FLUSHDB` 仅用于隔离测试环境，不能在生产环境使用。

每轮测试需要使用独立的日志文件。

不能用多轮混合日志统计某一轮的 Redis 申请次数。

## 12.2 日志要求

建议统一结构化记录：

```text
request_id
kong_node
worker_pid
key
batch
granted
local_remaining
decision
redis_error
```

至少需要区分：

```text
redis_grant
local_fill
local_hit
limited
redis_error
```

日志不能直接输出敏感 Header 的原始内容。

## 12.3 关键指标

建议增加 Prometheus 指标：

```text
rate_limit_requests_total
rate_limit_allowed_total
rate_limit_limited_total
rate_limit_redis_requests_total
rate_limit_redis_errors_total
rate_limit_local_hit_total
rate_limit_local_fill_total
rate_limit_local_tokens
rate_limit_grant_total
```

指标标签建议：

```text
node
decision
```

不要把完整 IP、Path、Header 等高基数数据直接作为 Prometheus 标签。

---

# 十三、最终测试报告格式

每个阶段必须生成报告。

统一采用：

```markdown
# 测试报告

## 1. 测试目的

## 2. 修改文件

## 3. 修改内容

## 4. 测试环境

## 5. 测试参数

## 6. 测试命令

## 7. 测试结果

| 指标 | 结果 | 预期 | 状态 |
|---|---|---|---|
| allowed | | | |
| limited | | | |
| other | | | |
| Redis 请求数 | | | |
| local_hit | | | |
| local_fill | | | |

## 8. 日志分析

## 9. 发现的问题

## 10. 风险分析

## 11. 是否通过验收

## 12. 下一阶段建议
```

所有报告必须基于真实执行结果。

禁止编造测试结果。

没有执行的测试必须标记为：

```text
NOT RUN
```

---

# 十四、当前版本的验收标准

第一版最终需要满足：

| 项目 | 验收标准 |
|---|---|
| Redis Lua | 原子令牌桶 |
| 时间 | 使用 Redis TIME |
| burst | 不超过桶容量 |
| batch=1 | 全局配额严格正确 |
| batch=N | 不超发 |
| Key | 支持多维规则组合 |
| Hash Tag | 正确使用 Redis Cluster Hash Tag |
| shared dict | 同一 Kong 节点内 Worker 共享 |
| 本地库存 | 原子扣减 |
| Redis 故障 | Fail-Closed，503 |
| 超限请求 | 429 |
| Retry-After | 合理计算 |
| TTL | 与令牌生命周期协调 |
| 测试 | 多节点并发及故障测试 |
| 报告 | 每阶段生成真实报告 |

---

# 十五、交给 DeepSeek 的开发执行指令

以下要求必须严格执行。

## 15.1 开发约束

你不是要重新设计一个全新的限流插件。

你需要基于现有 `rate-limit-advanced` 项目进行迭代开发。

必须遵守：

1. 不允许一次性重写全部代码。
2. 不允许未经分析就修改 Redis Key 格式。
3. 不允许随意改变现有 Token Bucket 语义。
4. 不允许为了性能牺牲全局配额正确性。
5. 不允许引入没有必要的外部依赖。
6. 不允许跳过测试。
7. 不允许编造测试报告。
8. 不允许忽略现有压测中出现的 batch 利用率波动。
9. 每次修改必须说明原因。
10. 每个阶段必须保留可回滚的代码版本。

## 15.2 开发流程

每个 Phase 按以下流程执行：

```text
读取现有代码
      |
      v
理解当前架构
      |
      v
列出问题和风险
      |
      v
提出最小修改方案
      |
      v
等待方案确认
      |
      v
修改代码
      |
      v
运行单元测试
      |
      v
运行集成测试
      |
      v
生成测试报告
      |
      v
人工验收
      |
      v
进入下一阶段
```

如果发现现有架构存在重大问题：

先说明问题、复现路径和影响范围。

不能擅自改变核心架构。

## 15.3 第一次执行任务

现在只执行：

**Phase 0：代码基线与架构审查。**

先不要修改任何代码。

请完整读取当前项目：

```text
handler.lua
schema.lua
lib/algorithm.lua
lib/redis.lua
lib/store.lua
bench/quota.sh
bench/common.sh
k6/quota.js
```

重点回答：

1. 当前请求完整执行链是什么？
2. Redis Lua 是否保证原子扣减？
3. store.take 是否真正原子？
4. store.fill 是否存在并发覆盖？
5. 三个 Kong 节点的库存是否正确隔离？
6. 同一节点多个 Worker 是否共享库存？
7. batch=20 为什么会出现利用率波动？
8. Redis TTL 与本地库存生命周期是否一致？
9. 当前 Fail-Closed 是否完整？
10. 当前实现还有哪些可能导致超发、少发或异常放行的问题？

输出：

```text
reports/phase-0-baseline.md
```

并给出：

- 当前架构图。
- 模块调用关系。
- 问题清单。
- 风险等级。
- 后续分阶段修改建议。

**等待人工确认后再进入 Phase 1。**

---

# 最终开发原则

本项目的核心不是简单实现一个 Redis 计数器。

真正需要解决的是：

**如何在多个 Kong 节点之间共享全局令牌配额，同时通过本地批量租赁减少 Redis 访问，并在流量不均衡、节点故障和并发竞争的情况下保证配额正确性。**

第一优先级：正确性。

第二优先级：分布式库存管理。

第三优先级：性能优化。

第四优先级：工程化与可观测性。

任何性能优化都必须建立在正确性验证通过的基础上。