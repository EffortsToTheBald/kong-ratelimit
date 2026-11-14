# 配置说明（以 schema.lua 为唯一依据）

> 所有字段来自 `kong/plugins/rate-limit-advanced/schema.lua`；文档不包含 Schema 之外的参数。
> 内部常量（如 Lease 元数据 TTL `LEASE_TTL_MS=3600000`）**不是用户可配置项**，不在本表。

## 1. 顶层字段

| 字段 | 类型 | 默认值 | 作用 | 限制 |
|---|---|---|---|---|
| `limit` | integer | **必填** | 每 window 秒允许的请求数（桶速率 rate=limit/window） | > 0 |
| `window` | number | 60 | 窗口长度（秒） | > 0 |
| `burst` | integer | 0 | 桶容量；0 = 跟随 limit（允许一个窗口内完整突发） | 0 ≤ burst ≤ 100000000；`≤0 归一化为 limit`（参与策略指纹） |
| `batch` | integer | 0 | 每次 Redis 领取的令牌数；**0 = auto（clamp(limit/50, 1, 50)）；1 = 严格全局一致；>1 = Lease 预授权** | 0 ≤ batch ≤ 100000000；**不参与策略指纹**；rules 模式下必须 0/1 |
| `limit_by` | array of string | ["ip"] | 限流维度，可组合 | 每元素 ∈ {consumer, ip, path, method, header, route, service}；len≥1；**与 rules 互斥**（rules 非空时显式设置即 400）；含 `header` 时 `header_name` 必填 |
| `header_name` | string | 无 | `limit_by` 含 "header" 时的取值头名 | 条件必填（缺失 ⇒ 下发 400） |
| `rules` | array of record | 无 | 多规则联合判定（α 强一致） | ≤ 8 条；与 `limit_by` 互斥；每条规则独立 limit/window/burst/limit_by/header_name |
| `namespace` | string | "rl" | 命名空间（隔离不同配置的全局桶） | — |
| `hide_client_headers` | boolean | false | 不回 X-RateLimit-* 头 | — |
| `fault_tolerant` | boolean | false | Redis 故障策略：false=Fail-close（503）；true=降级放行（X-RateLimit-Status: degraded） | — |
| `redis.host` | string | "127.0.0.1" | Redis 地址 | — |
| `redis.port` | integer | 6379 | Redis 端口 | 1–65535 |
| `redis.password` | string | 无 | 认证密码 | — |
| `redis.database` | integer | 0 | 逻辑库 | 0–15 |
| `redis.timeout` | integer | 1000 | 连接/读写超时（ms）；超时的 GRANT 视为**不确定结果** | 1–60000 |
| `redis.key_prefix` | string | "kong:rl" | Redis Key 前缀 | — |

### 每条规则（rules[i]）字段

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `limit` | integer | **必填** | 该规则配额 |
| `window` | number | 60 | 该规则窗口 |
| `burst` | integer | 0 | 该规则桶容量 |
| `limit_by` | array | ["consumer"] | 该规则维度（组合键） |
| `header_name` | string | 无 | 该规则含 header 维度时必填 |

## 2. 三种模式由什么决定

| 条件 | 模式 | Redis 行为 | 本地库存 |
|---|---|---|---|
| 无 rules 且 `batch=1` | 逐请求授权 | 每请求 EVALSHA token_bucket | 无 |
| 无 rules 且 `batch>1` | Lease 预授权 | 库存不足时 GRANT_LEASE | 有（Worker 私有） |
| 无 rules 且 `batch=0` | Lease 预授权（auto） | 同上，batch=clamp(limit/50,1,50) | 有 |
| 有 rules | 多规则原子授权 | 每请求 GRANT_MULTI（全或无） | 无（batch 必须 0/1） |

## 3. 策略指纹与配置变更

- **参与指纹**：`limit / window / burst（归一化后）/ limit_by 顺序 / header_name（仅含 header 维度时）`
- **不参与**：`batch`（运输参数——调整 batch 不清空全局桶）、`namespace` 之外的行为参数、
  `fault_tolerant`/`hide_client_headers`/`redis.*`（连接与呈现参数）
- **配置变更语义**：任何参与指纹的字段变化 ⇒ 新 Pool Key（全局桶从满额开始，旧桶/旧 Lease 记录随
  TTL 自然消亡）。改配置前评估"配额重置"的业务影响；需要继承余量请换 `namespace`。
- **旧 Pool 生命周期回收尚未实现（Deferred）**

## 4. 故障处理相关

- `fault_tolerant=false`（默认）：Redis 故障/超时 ⇒ **503 Fail-close**；绝不伪装 429
- `fault_tolerant=true`：降级放行 + `X-RateLimit-Status: degraded`
- `redis.timeout`：GRANT 超时 ⇒ **不确定结果**（Redis 可能已执行扣减与建 Lease 记录）：
  不重试、不登记本地库存，可能造成库存损失（冻结语义）
- 429 携带 `Retry-After`（封顶 window；多规则 = 不足规则等待的最大值封顶）

## 5. 不支持的配置组合

| 组合 | 结果 |
|---|---|
| `rules` 非空 + 显式 `limit_by` | 下发 400（互斥；rules 模式下省略 limit_by 即可） |
| `rules` 非空 + `batch > 1` | 下发 400（强一致模式无 Lease） |
| `rules` 长度 > 8 | 下发 400 |
| `limit_by` 含 `header` 而 `header_name` 缺失 | 下发 400（顶层与每条规则同语义） |
| `limit` ≤ 0 / `window` ≤ 0 / `batch` 越界 | 下发 400 |
