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


### Requirement: 多维维度组合独立计数
limit_by 的维度组合必须（MUST）参与 Redis key 的 hash tag 计算：不同维度组合映射到不同桶；相同组合与相同维度值稳定映射到同一个桶；任一维度值不同即分桶。

#### Scenario: ip+path 组合下不同 path 独立计数
- **WHEN** 配置 limit_by=[ip, path]、limit=2，依次请求 /echo 与 /echo/foo 各 2 次
- **THEN** 两条路径各有 2 个请求放行（第 3 个同路径请求返回 429），互不共享配额

#### Scenario: 维度顺序不同即不同桶
- **WHEN** 分别以 limit_by=[ip, path] 与 limit_by=[path, ip] 下发同值配置
- **THEN** 两者产生不同指纹、不同 key，互不共享桶

### Requirement: method 维度按 HTTP 方法分桶
method 维度必须（MUST）以请求的 HTTP 方法作为取值参与 key 计算。

#### Scenario: GET 与 POST 分桶
- **WHEN** 配置 limit_by=[method]、limit=1，先发 GET 再发 POST
- **THEN** 两个请求都被放行（各自方法桶的首次），随后同方法第二次请求返回 429

### Requirement: header 维度按指定头取值分桶
header 维度必须（MUST）以 `header_name` 指定头的取值作为维度值；该头缺失的请求必须（MUST）共用同一缺失哨兵桶，不与任何具名值桶共享。

#### Scenario: 不同头值分桶、缺失值共用哨兵
- **WHEN** 配置 limit_by=[header]、header_name=X-Tenant、limit=1，携带 X-Tenant: a 与 X-Tenant: b 各 1 次，再各发 1 次，最后连发 2 次不带该头
- **THEN** a、b 首次均放行、各自第二次返回 429；首个"无头"请求放行（独立哨兵桶）、第二个"无头"请求返回 429；无头请求不占用 a/b 的桶

### Requirement: consumer 维度按认证身份分桶
consumer 维度必须（MUST）以认证插件解析出的 consumer 身份作为取值；未认证请求共用 anon 哨兵桶。

#### Scenario: 认证后不同 consumer 独立配额
- **WHEN** 路由启用 key-auth，consumer alice/bob 各持有效 key，配置 limit_by=[consumer]、limit=1
- **THEN** alice 与 bob 各自首个带 key 请求放行、第二个返回 429，两者配额互不影响

#### Scenario: 未认证请求共用 anon 桶
- **WHEN** 同上配置下发送不带 key 的请求
- **THEN** 全部落入 anon 桶计数（不与 alice/bob 桶共享）

### Requirement: route/service 维度参与 key 计算
route 与 service 维度必须（MUST）以命中的 route.id / service.id 作为取值参与 key 计算；未命中时使用哨兵值。

#### Scenario: route 维度生效
- **WHEN** 配置 limit_by=[route]、limit=1 且请求命中已有路由
- **THEN** key 中含该 route 的 id 取值，首个请求放行、第二个返回 429

### Requirement: header 维度的 header_name 配置前置校验
limit_by 含 header 而 header_name 缺失/为空的配置必须（MUST）在配置下发时被拒绝（HTTP 400），不得进入运行时。

#### Scenario: 坏配置下发即被拒
- **WHEN** 向 Admin API 下发 limit_by=[header] 且未提供 header_name 的插件配置
- **THEN** Admin API 返回 400 并说明 header_name 必填（运行时不再出现 500）

### Requirement: X-RateLimit-Reset 为下一个令牌可用时刻
X-RateLimit-Reset 必须是（MUST）"下一个令牌可用的 Unix 秒"：Redis 授予路径由服务端返回的等待时长推导，本地库存路径为本节点视角（有库存即视为当前可用）；该口径必须（MUST）与 Retry-After 一致（429 时 Reset−now ≈ Retry-After）。

#### Scenario: 429 时 reset 与 Retry-After 同口径
- **WHEN** 桶被耗尽后收到 429
- **THEN** X-RateLimit-Reset 为未来某 Unix 秒，且其与响应时刻的差值等于 Retry-After 秒数（±1 秒容差）

### Requirement: Retry-After 有上限
Retry-After 必须（MUST）不超过配置的 window 秒。

#### Scenario: 小 rate 配置下 Retry-After 被封顶
- **WHEN** 配置 limit=1、window=3600，触发 429
- **THEN** Retry-After ≤ 3600（不出现超过 window 的等待值）

### Requirement: 429 拒绝可观测
每个被 429 拒绝的请求必须（MUST）产生一条包含限流 key、limit 与 batch 的日志，使限流拒绝可与 Redis 故障区分。

#### Scenario: 429 产生判定日志
- **WHEN** 请求因超配额被拒
- **THEN** 日志出现该请求的 key 与 limit 信息，且可由日志检索区分于 503 故障路径

### Requirement: Redis 畸形返回走故障分支
Redis EVAL 返回值不是 3 元数值数组时必须（MUST）视为 Redis 异常：返回 nil 并进入故障分支（默认 503 / 显式容错 degraded），不得基于畸形数据放行、拒绝或抛出 Lua 异常。

#### Scenario: 畸形返回不产生 500 与异常放行
- **WHEN** Redis 对 EVAL 返回畸形数据（如空表或非数值）
- **THEN** 请求得到 503（默认配置）或 degraded 放行（显式容错），日志记录防御性校验失败，无 Lua traceback

### Requirement: shared dict 缺失时启动告警
lua_shared_dict 不可用导致本地库存降级为 worker 私有表时，系统必须（MUST）在启动阶段输出 warning 日志。

#### Scenario: 降级配置启动即告警
- **WHEN** 以移除 KONG_NGINX_HTTP_LUA_SHARED_DICT 的方式启动 Kong
- **THEN** 启动日志出现本地库存降级的 warning，功能仍以 worker 表降级运行

### Requirement: 多规则联合判定为全或无原子操作
一个请求同时受 `rules` 声明的全部规则约束：全部规则桶都有令牌时，系统必须（MUST）从每个桶各消耗 1 个令牌并放行；任一规则桶令牌不足时，系统必须（MUST）拒绝请求且**所有桶都不消耗**——检查与扣减必须（MUST）在 Redis 服务端单脚本内原子完成。

#### Scenario: 一桶空一桶有 ⇒ 拒绝且双桶不变
- **WHEN** 预置规则 R1（consumer 全局）桶 tokens=0、规则 R2（consumer×path）桶 tokens=5，随后发起一次同时命中两条规则的请求
- **THEN** 响应为 429，且 R1、R2 两桶的 tokens 在请求前后均不变（R2 不被消耗）

#### Scenario: 全部桶有令牌 ⇒ 各扣 1 放行
- **WHEN** R1、R2 桶均有 ≥1 个令牌时发起一次请求
- **THEN** 请求放行，且每个桶的 tokens 恰好各减 1

### Requirement: 组键结构与组指纹
多规则的全部桶必须（MUST）落在同一个 hash tag 内（`kong:rl:{<ns>:<组指纹>:r<i>:…}`），组指纹由全部规则参数共同派生；任一规则参数变更必须（MUST）使整组映射到新键（旧桶随 TTL 淘汰）。

#### Scenario: 修改任一规则 ⇒ 整组换桶
- **WHEN** 以相同 namespace 下发 rules，仅修改其中一条规则的 limit
- **THEN** 全部规则的桶键的组指纹段变化（旧组桶不再被命中）

#### Scenario: 组内桶同 hash tag
- **WHEN** 检查一次请求涉及的全部桶键
- **THEN** 各键的 hash tag 内容相同（同 Redis Cluster slot 的前置条件）

### Requirement: 强一致模式的配置约束
`rules` 模式必须（MUST）满足以下配置约束，违反即在下发时被拒绝（HTTP 400）：`rules` 与 `limit_by` 不得同时显式声明（互斥）；`rules` 非空时 `batch` 必须（MUST）为 0 或 1（无租约语义）；规则数必须（MUST）不超过 8。

#### Scenario: 三类坏配置下发即被拒
- **WHEN** 分别下发 a) rules 与 limit_by 同现、b) rules 非空且 batch=20、c) 9 条规则的配置
- **THEN** 三次下发均返回 400 并说明原因

#### Scenario: 合法 rules 配置正常下发
- **WHEN** 下发 2 条规则、batch=0 的合法配置
- **THEN** 下发成功（2xx）

### Requirement: 多规则响应语义
多规则模式下：放行时 `X-RateLimit-Remaining` 必须（MUST）为各桶剩余的最小值（瓶颈规则）、`X-RateLimit-Reset` 必须（MUST）为瓶颈规则的下一令牌可用时刻；429 响应体必须（MUST）含 `rule` 字段标明不足的规则、`Retry-After` 必须（MUST）为各不足规则等待值的最大值（封顶为相应 window 的最大值）。

#### Scenario: 瓶颈规则决定响应头
- **WHEN** 放行一次多规则请求（R1 剩余 3、R2 剩余 1）
- **THEN** X-RateLimit-Remaining 为 1（瓶颈），Reset 对应 R2 的下一令牌时刻

#### Scenario: 429 标明拒绝规则与等待
- **WHEN** R1 空、R2 有 5 个令牌时请求被拒
- **THEN** 响应体 `rule` 指向 R1，Retry-After ≤ R1 的 window

### Requirement: 单规则形态行为不回归
未配置 `rules`（仅 `limit_by`）时，系统必须（MUST）保持既有全部行为：单桶复合键、本地库存 batch 租赁、既有响应头语义。

#### Scenario: 旧配置回归
- **WHEN** 以 Phase 2 的既有配置（limit_by=[ip]、batch=20）复跑 batch 基线
- **THEN** 结果与既有验收锚点一致（450 请求、batch=1 时恰 100 放行）
