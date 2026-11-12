# Spec Delta

## ADDED Requirements

### Requirement: EVALSHA 脚本管理
插件必须（MUST）以模块内脚本表统一管理四个 Lua 脚本（TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE）的源文本与 SHA，脚本名称唯一稳定、同一文本不得（MUST NOT）多模块重复维护；init_worker 不得（MUST NOT）直接执行 cosocket Redis IO，装载必须（MUST）经 timer 或懒加载完成，失败只 warn 一次且不影响初始化。运行期必须（MUST）以 EVALSHA 执行；**明确 NOSCRIPT** ⇒ SCRIPT LOAD 并只重试一次；超时不得（MUST NOT）当作 NOSCRIPT；其他错误不得（MUST NOT）无限重试；装载与自愈不得（MUST NOT）造成重复扣减。GRANT 与 RETURN 的恢复路径必须（MUST）分别验证。

#### Scenario: init 阶段 Redis 不可用 ⇒ 初始化不受阻
- **WHEN** 脚本装载 timer 执行时 Redis 不可用
- **THEN** 插件正常完成初始化（warn 一次），首个真实请求触发懒加载；仍失败按配置走 503/降级，无 Lua 异常

#### Scenario: NOSCRIPT 自愈且不重复扣减（GRANT 与 RETURN 分别验证）
- **WHEN** Redis `SCRIPT FLUSH` 后分别触发 GRANT 路径与 RETURN 路径的请求
- **THEN** 各自自动重载并重试恰好一次，桶扣减/归还均恰为一次（HGET 前后对照）

#### Scenario: 超时不被当作 NOSCRIPT
- **WHEN** EVALSHA 超时（Redis 无响应）
- **THEN** 不触发 SCRIPT LOAD 重载；按超时语义处理（GRANT：不重试允许损失；RETURN：进入幂等重试策略）

#### Scenario: 行为零回归
- **WHEN** 切换 EVALSHA 后复跑既有回归套件（quota batch=1、dims.sh、rules.sh）
- **THEN** 全部结果与既有锚点一致

### Requirement: 性能基线与对比测量
性能数据必须（MUST）来自真实运行：先以现有 EVAL 实现测量基线，EVALSHA 落地后同参数复测。测试矩阵必须（MUST）覆盖：batch（1/10/50/100）、请求速率（低/中/高）、Kong Worker 数（1/多）、规则数量（单/多规则）、执行方式（EVAL/EVALSHA）、RETURN 开关（关/开）、Redis（正常/故障恢复）。每组记录 RPS、p50/p95/p99、Redis QPS、Redis CPU、Kong CPU、GRANT 次数、RETURN 次数、实际归还量、丢弃量、本地库存损失、限流误差。不得（MUST NOT）编造数据；未执行的测试必须（MUST）标注 NOT RUN 及原因。

#### Scenario: 基线先于复测且矩阵维度齐全
- **WHEN** EVALSHA 改造合入前
- **THEN** EVAL 基线已落盘 `bench/results.md`；复测与基线同参数对照，矩阵维度无缺漏或逐项 NOT RUN

### Requirement: Lease 模式适用边界
Worker 本地 Lease 机制仅（ONLY）适用于**单规则 batch>1**（batch 经 auto 解析后 >1）：batch=1 保持既有严格 Redis 路径（每请求一次 Redis、不创建 Lease、语义零变化）；多规则继续使用既有 Redis 原子多键流程（先全检、全过统一扣减、任一不足全不扣、Fail-Closed 语义不变），且不得（MUST NOT）使用本地 Lease；Lease 机制对 batch=1 与多规则必须（MUST）为 no-op（零 Lease 创建、零 RETURN、零相关错误日志）。

#### Scenario: batch=1 严格路径零变化
- **WHEN** 以 batch=1 配置复跑 Phase 1 基线（450 请求恰 100 放行）与故障双路径
- **THEN** 结果与既有锚点一致，Redis 中无 Lease 记录

#### Scenario: 多规则路径零变化
- **WHEN** 复跑 rules.sh 全场景
- **THEN** 全绿且 Redis 中无 Lease 记录；多规则"一空一有 ⇒ 429 且双桶不变"语义不变

#### Scenario: 单规则 batch>1 使用 Lease
- **WHEN** 以 batch=20 配置发起请求
- **THEN** 首次请求经 GRANT 创建 Lease（Redis 可见 lease 记录，状态 OPEN），后续请求本地 TAKE 消费，无每请求 Redis 操作

### Requirement: Lease 所有权与本地状态机
每个 Lease 必须（MUST）只属于创建它的 Worker（Worker 级 Lua table 持有，不共享、不使用 ngx.shared.DICT 聚合库存）；状态机必须（MUST）为 ACTIVE→CLOSING→CLOSED 单向，禁止 CLOSING 回 ACTIVE、CLOSED 重入消费、同一 Lease 关闭两次。TAKE 必须（MUST）在**不含 yield 点的同一同步片段**内完成查找/检查/递减/更新 last_used_at，remaining 不得（MUST NOT）为负、不得（MUST NOT）有补偿路径。关闭必须（MUST）本地先行——置 CLOSING、从 ACTIVE 集合摘除、快照 remaining 为 requested、置 remaining=0（同一非 yield 片段）——之后才调用 Redis RETURN（允许 yield）。关闭后的 Lease 不得（MUST NOT）被消费。

#### Scenario: TAKE 无 yield 且无负库存
- **WHEN** 请求在活跃 Lease 上 TAKE
- **THEN** 检查与递减在同一非 yield 片段完成（代码审查 + 协议级测试断言），remaining 单调非负，无补偿路径

#### Scenario: 关闭先于 RETURN 且摘除即时
- **WHEN** Timer 决定关闭某 Lease 并在 RETURN 期间发生 yield
- **THEN** 该 Lease 在 yield 前已置 CLOSING 并从 ACTIVE 集合摘除，期间任何请求 TAKE 不能消费它，后续 GRANT 创建的独立 Lease 不受影响

#### Scenario: 关闭后不可消费
- **WHEN** Lease 进入 CLOSING/CLOSED 后请求 TAKE
- **THEN** 该 Lease 不再被选中；请求使用同池其他 ACTIVE Lease 或触发新 GRANT

#### Scenario: 多 Worker 隔离
- **WHEN** Worker A 与 Worker B 各自 GRANT 创建 Lease A/B
- **THEN** A 只能消费与关闭 A，B 只能消费与关闭 B；A 崩溃不影响 B 的 Lease 与消费

### Requirement: Lease 生命周期管理
每个 Lease 必须（MUST）具备两个关闭条件：idle（now−last_used_at ≥ `lease_return_idle`，默认 10s，0–3600，0=禁用空闲触发）或 age（now−created_at ≥ `lease_max_lifetime`，默认 300s，10–3600，强制轮换不得（MUST NOT）关闭）；`max_lifetime ≥ idle` 必须（MUST）由配置校验强制。本地间隔必须（MUST）使用真正单调时钟（CLOCK_MONOTONIC 语义；不得（MUST NOT）以 ngx.now()/update_time 或 max 包装声称单调、不得（MUST NOT）用 Redis TIME）；环境无可靠实现必须（MUST）停止生命周期实现并报告限制；时钟必须（MUST）可注入。每个 Worker 必须（MUST）运行 1 秒扫描器（仅本 Worker）并具备重入保护（辅助措施）。关闭阈值必须（MUST）取自创建时配置快照，不得（MUST NOT）追溯既有 Lease。

#### Scenario: 空闲超时关闭
- **WHEN** Lease 的 last_used_at 距今 ≥ lease_return_idle
- **THEN** 扫描器关闭该 Lease（CLOSING → RETURN → CLOSED）

#### Scenario: 最大生命周期强制关闭
- **WHEN** Lease 持续有请求消费、idle 条件始终不满足，age 达到 lease_max_lifetime
- **THEN** Lease 被强制关闭并归还剩余库存；关闭后不能继续消费；后续请求创建新 Lease

#### Scenario: idle=0 时最大生命周期仍生效
- **WHEN** lease_return_idle=0 且 Lease 达到 lease_max_lifetime
- **THEN** 仍被强制关闭归还（最大生命周期不可关闭）

#### Scenario: 配置快照隔离
- **WHEN** 运行中修改 lease_return_idle/lease_max_lifetime
- **THEN** 已存在 Lease 按创建时快照的阈值关闭，新 Lease 使用新阈值，无追溯修改

### Requirement: GRANT 原子性与超时语义
Lease 授予必须（MUST）由单个 Redis Lua 脚本原子完成：参数校验 → 桶读取/refill（elapsed = max(0, now−ts)；rate/capacity 与 TOKEN_BUCKET/RETURN_LEASE 采用统一来源，不得（MUST NOT）各脚本不一致）→ 授予判定与扣减（部分授予允许；tokens<1 ⇒ granted=0 且**不创建 Lease**）→ 创建唯一 Lease 记录（status=OPEN）→ 设置 TTL ⇒ 返回 granted。不得（MUST NOT）先扣桶再由客户端单独建记录；关键步骤失败不得（MUST NOT）返回成功。lease_id 必须（MUST）全局唯一，同 ID 记录已存在 ⇒ 拒绝（LEASE_EXISTS）进入故障分支，不得（MUST NOT）换 ID 重试。GRANT 结果不明确（超时）时不得（MUST NOT）自动重试（同 ID/新 ID 均禁止），允许库存损失；Redis 已执行的场景下记录与扣减均已生效。

#### Scenario: GRANT 原子创建
- **WHEN** 本地无可用库存时发起 GRANT
- **THEN** 单脚本内完成桶 refill/扣减与 Lease 记录创建（OPEN）；脚本失败时无"已扣桶但无 Lease 记录"的返回成功

#### Scenario: 令牌不足
- **WHEN** 桶内 tokens < 1
- **THEN** granted=0、不创建 Lease 记录、请求按既有语义 429

#### Scenario: GRANT 超时不盲目重试
- **WHEN** GRANT 超时（Redis 可能已执行：桶已扣、Lease 已创建）
- **THEN** 客户端不重试（同 ID 或新 ID 均不得）；该批库存计入损失；请求按故障分支处理

#### Scenario: Lease ID 冲突拒绝
- **WHEN** GRANT 提交的 lease_id 在 Redis 已存在记录
- **THEN** 返回 LEASE_EXISTS 明确错误，不覆盖不幂等重放，进入故障分支

### Requirement: RETURN 写入顺序与幂等提交点
RETURN 必须（MUST）由单个 Redis Lua 脚本完成，写顺序必须（MUST）为**先提交 RETURNED 幂等标记（含 return_requested 字段记录首次归还量），后一次 HSET 写入完整 Bucket 状态**（refill→+requested→capacity 封顶；requested=0 仍完成标记跳过桶更新）——标记是幂等提交点：标记成功后任何桶更新失败 ⇒ 重试得 ALREADY_RETURNED 不再加桶（损失允许）；"先加桶后标记"必须（MUST）禁止（Redis Lua 运行时错误不回滚 ⇒ 会产生桶已加而 Lease 仍 OPEN 的重复归还风险）。返回 requested/applied/discarded（applied+discarded=requested，0≤applied≤requested）；封顶丢弃计丢失，不得（MUST NOT）因封顶恢复 OPEN；同 lease_id 的桶库存增加次数必须（MUST）≤1。

#### Scenario: 标记后桶更新失败 ⇒ 重试不重复归还
- **WHEN** 脚本在写入 RETURNED 标记后、Bucket HSET 前发生异常，客户端以原参数重试
- **THEN** 返回 ALREADY_RETURNED，桶不再增加；差额计入损失（不得（MUST NOT）重复归还）

#### Scenario: 正常归还三元组与封顶
- **WHEN** 归还时桶有余量/部分余量/已满
- **THEN** applied+discarded=requested 且 0≤applied≤requested；全封顶 ⇒ applied=0、discarded=requested 计丢失

#### Scenario: requested=0 仍完成状态转换
- **WHEN** Lease 库存全部消费后关闭（requested=0）
- **THEN** 不修改桶，状态仍 OPEN→RETURNED（账目闭合）

### Requirement: RETURN 校验与错误码语义
RETURN 的全部校验必须（MUST）先于任何写且失败零写入：记录不存在 ⇒ LEASE_NOT_FOUND（不得（MUST NOT）加桶）；status=RETURNED ⇒ 同 requested 得 ALREADY_RETURNED、不同 requested 得 RETURN_CONFLICT（不得（MUST NOT）视为相同重试）；非 OPEN ⇒ INVALID_LEASE_STATE；pool_key 不匹配 ⇒ POOL_MISMATCH；requested > granted ⇒ INVALID_REQUESTED；Bucket 不存在 ⇒ BUCKET_NOT_FOUND 拒绝（不得（MUST NOT）在新 Bucket 补偿旧 Lease）；参数非法 ⇒ INVALID_ARGUMENT。结果不明确（超时/连接中断）⇒ 仅原 lease_id + 原 requested 有限重试（总计 ≤3 次尝试；明确错误不重试），达上限允许损失；禁止换 ID 重试、禁止把 LEASE_NOT_FOUND 当成功。

#### Scenario: 同 ID 不同 requested ⇒ RETURN_CONFLICT
- **WHEN** Lease 已 RETURNED（return_requested=5）后以 requested=3 再次提交
- **THEN** 返回 RETURN_CONFLICT，桶不增加

#### Scenario: Bucket 不存在 ⇒ BUCKET_NOT_FOUND
- **WHEN** RETURN 时目标 Bucket 已过期/不存在
- **THEN** 返回 BUCKET_NOT_FOUND，零写入；该批库存计入损失

#### Scenario: 有限重试与错误分类
- **WHEN** RETURN 超时后以原 ID+原 requested 重试至多 2 次（总 3 次尝试）仍不明确；或收到参数/状态类明确错误
- **THEN** 明确错误不重试；达上限停止并允许损失；任何情况下桶库存增加次数 ≤1

#### Scenario: 正常归还三元组
- **WHEN** Lease 以 requested=剩余库存关闭并 RETURN（桶有余量/部分余量/已满）
- **THEN** 返回 requested/applied/discarded 且 0 ≤ applied ≤ requested、discarded = requested − applied；Lease 状态 OPEN→RETURNED；封顶丢弃计入丢失

#### Scenario: 幂等重试不重复增加令牌
- **WHEN** 首次 RETURN 已在 Redis 执行成功但响应丢失，客户端以相同 lease_id + 相同 requested 重试
- **THEN** Redis 返回 ALREADY_RETURNED，桶不再增加，无重复归还

#### Scenario: 并发 RETURN 幂等
- **WHEN** 两个 RETURN（同 Lease）并发到达
- **THEN** Redis 串行执行：先到者完成 OPEN→RETURNED，后者得到 ALREADY_RETURNED，桶只增加一次

#### Scenario: Lease 记录过期拒绝归还
- **WHEN** Lease 记录已过期（TTL 消亡）后提交 RETURN
- **THEN** 返回 LEASE_NOT_FOUND，桶不增加（不得推测库存归还），该批库存计入损失

#### Scenario: 同 ID 不同 requested ⇒ RETURN_CONFLICT
- **WHEN** Lease 已 RETURNED（return_requested=5）后以 requested=3 再次提交
- **THEN** 返回 RETURN_CONFLICT，桶不增加（不同 requested 不得（MUST NOT）被视为相同重试）

#### Scenario: Bucket 不存在 ⇒ BUCKET_NOT_FOUND
- **WHEN** RETURN 时目标 Bucket 已过期/不存在
- **THEN** 返回 BUCKET_NOT_FOUND，零写入；禁止在新 Bucket 补偿旧 Lease；该批库存计入损失

#### Scenario: RETURNED 标记成功但 Bucket 更新失败 ⇒ 重试不重复归还
- **WHEN** 脚本在写入 RETURNED 标记后、Bucket HSET 前发生异常，客户端以原参数重试
- **THEN** 返回 ALREADY_RETURNED，桶不再增加；该批差额计入损失（不得（MUST NOT）重复归还）

#### Scenario: requested=0 归还
- **WHEN** Lease 库存全部消费后关闭（requested=0）
- **THEN** 不修改桶，Lease 状态仍转换 OPEN→RETURNED（账目闭合）

#### Scenario: 有限幂等重试
- **WHEN** RETURN 超时后按原 ID + 原 requested 重试，达到次数/时间上限仍不明确
- **THEN** 停止重试，库存损失，日志 outcome=uncertain；参数/状态类明确错误不进入重试

### Requirement: 配置变更隔离与账目边界
`pool_key` 必须（MUST）包含配置版本（复用既有策略指纹）：配置变更产生新 pool_key，新配置不得（MUST NOT）消费旧 Lease；旧 Lease 按创建时快照的生命周期参数完成消费与归还，生命周期配置变更不得（MUST NOT）追溯既有 Lease。对**明确的 Lease 集合**必须（MUST）满足 `granted = consumed + returned_applied + lost` 且 `consumed + returned_applied ≤ granted`；生产环境不承诺精确总账，只提供保守损失上界。Worker 崩溃只允许（MUST）造成库存损失，不得（MUST NOT）造成额度重复或跨 Worker 补偿。

#### Scenario: 配置变更隔离
- **WHEN** 修改 limit（新指纹）后旧池 Lease 仍有剩余
- **THEN** 旧 Lease 按创建时快照的阈值完成消费或归还，新流量走新 pool_key 的新 Lease，无混用

#### Scenario: 确定性账目闭合
- **WHEN** 无故障的确定性序列（GRANT 100、消费 80、关闭归还 20）
- **THEN** 该 Lease 集合：granted 100 = consumed 80 + returned_applied 20 + lost 0

#### Scenario: Worker 崩溃仅损失库存
- **WHEN** Worker 在 Lease ACTIVE 或 CLOSING（RETURN 未完成）时崩溃
- **THEN** 该 Worker 剩余库存无法归还（Lease 记录 TTL 后消亡），granted − consumed − returned_applied = lost；不超发、不重复归还、其他 Worker 不受影响
