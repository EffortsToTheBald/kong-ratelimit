# Spec Delta

## ADDED Requirements

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
