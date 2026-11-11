# rate-limiting Specification

## Purpose

定义多 Kong 节点共享全局令牌桶配额的核心正确性行为：桶的策略身份隔离、batch=1 严格模式与 batch=N 租赁模式的配额边界、令牌补充与时间单调性、Redis 故障的默认 fail-closed 策略，以及 IP 维度取值的信任语义。本能力是 `rate-limit-advanced` 插件正确性的权威行为契约。

规范用词约定：**必须（MUST）** 与 **不得（MUST NOT）** 为强制要求；"应当"为建议；"可以"为可选。每个 Requirement 的首个规范词附英文括注以满足校验器。

## Requirements

### Requirement: 限流桶按策略指纹隔离
系统必须（MUST）为每条限流策略派生一个策略指纹（由 limit、window、burst 的解析值、limit_by 维度列表以及 header_name 共同确定），并将其编入 Redis key 的 hash tag 之内。不同策略必须得到相互独立的桶；同一策略必须稳定映射到同一个桶。

#### Scenario: 配置变更不继承旧配额
- **WHEN** 将运行中的 limit=1000 配置改为 limit=100 后立即发起超额请求
- **THEN** 全局放行数不超过新 limit（不继承旧桶或旧本地库存中的剩余令牌）

#### Scenario: 同策略跨节点稳定同 key
- **WHEN** 三个 Kong 节点下发完全相同的限流配置并对相同维度值的请求进行访问
- **THEN** 三节点命中同一个 Redis key（全局只有一个桶）

### Requirement: batch=1 为严格全局一致模式
当 batch=1 时，系统必须（MUST）对每个请求直接向 Redis 原子申请令牌，不得从本地库存扣减，也不得向本地库存写入。

#### Scenario: batch=1 全局恰好放行 limit 个
- **WHEN** 3 个节点以 batch=1、limit=100、window=3600 各发送 150 个并发请求（合计 450）
- **THEN** 全局放行数恰为 100、限流数恰为 350、异常数为 0，且本地库存命中次数为 0

#### Scenario: batch=1 不产生本地库存
- **WHEN** batch=1 的一轮压测结束后检查各节点本地库存
- **THEN** 该策略 key 的本地库存不存在或为空

### Requirement: batch=N 模式不超发
当 batch=N（N>1）时，系统必须（MUST）保证放行请求数不超过 Redis 全局桶已授权的令牌数；任何节点不得独立于全局桶获得额外配额。

#### Scenario: batch=20 放行数不超过 limit
- **WHEN** 3 个节点以 batch=20、limit=100、window=3600（补充速率在单轮测试时长内可忽略）各发送 150 个并发请求
- **THEN** 全局放行数不超过 100

#### Scenario: 节点数量不放大配额
- **WHEN** 增减参与请求的 Kong 节点数量而保持策略不变
- **THEN** 全局配额语义不变（放行上界仍由全局桶决定，与节点数无关）

### Requirement: batch=N 模式少发有工程上界
当 batch=N（N>1）且本地库存生命周期管理正确时，因库存滞留造成的少发必须（MUST）满足：单轮全局放行数 ≥ max(0, limit − 节点数 × batch)。该边界为工程验收参考（依赖测试期间补充可忽略、每节点单一库存池）。

#### Scenario: batch=20 均匀流量下放行数达到下界
- **WHEN** 3 个节点以 batch=20、limit=100 均匀发送 450 个并发请求
- **THEN** 全局放行数 ≥ max(0, 100 − 3×20) = 40

### Requirement: Redis 不可用时默认 Fail-Closed
当 fault_tolerant 处于默认值（false）且 Redis 不可用（连接失败、认证失败、EVAL 失败、超时或返回异常数据）时，系统必须（MUST）以 HTTP 503 拒绝请求，且不得将请求转发到上游。

#### Scenario: 停止 Redis 后默认返回 503
- **WHEN** 停止 Redis 后发送请求且配置未显式设置 fault_tolerant
- **THEN** 响应为 HTTP 503，且上游未收到该请求

#### Scenario: Redis 故障不得产生 HTTP 500
- **WHEN** Redis 在请求处理中返回错误、超时或异常返回值
- **THEN** 响应码仅可能为 200/429/503，不出现 500

### Requirement: 显式容错模式放行并标记 degraded
当 fault_tolerant=true 且 Redis 不可用时，系统必须（MUST）放行请求并设置响应头 X-RateLimit-Status: degraded。

#### Scenario: 容错模式降级放行
- **WHEN** 停止 Redis 后发送请求且配置显式设置 fault_tolerant=true
- **THEN** 请求被放行，且响应头包含 X-RateLimit-Status: degraded

### Requirement: 令牌补充基于 Redis 时间且时间戳单调
系统必须（MUST）使用 Redis 服务端时间计算令牌补充（tokens += elapsed × rate，封顶 burst），且桶内补充时间戳不得回退——时钟回拨期间不得对同一时间段重复发放令牌。

#### Scenario: 补充量符合速率公式且封顶 burst
- **WHEN** 桶被耗尽后等待已知时长 t 再发起请求
- **THEN** 新增可用令牌数不超过 ⌈t × rate⌉，且桶内令牌数不超过 burst

#### Scenario: 时间戳不回退、回拨不重复计费
- **WHEN** 预置桶的补充时间戳为未来时刻后发起请求
- **THEN** 本次不发生补充，且桶内时间戳保持原值不被覆盖为更早时间

### Requirement: IP 维度取值遵循 Kong realip 信任语义
ip 维度的取值必须（MUST）是 Kong realip 配置解析后的客户端地址（trusted_ips 未配置时即为直接对端 IP）；来自非信任对端的伪造 X-Forwarded-For 不得改变 ip 维度的取值。

#### Scenario: 伪造 XFF 不产生新桶
- **WHEN** 同一来源 IP 的请求携带任意伪造的 X-Forwarded-For 头并以 limit=1、batch=1 发送
- **THEN** 仅首个请求放行，后续携带不同伪造 XFF 的请求均返回 429（始终命中同一桶）
