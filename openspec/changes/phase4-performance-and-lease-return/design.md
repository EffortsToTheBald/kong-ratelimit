# Design

## Context

**已核实的实现事实**（2026-11-12，容器实测）：

1. Kong 3.6 无插件级 exit_worker 钩子；退出期 timer 行为未证实（1.3 实测定分支）。
2. init_worker 阶段不能直接跑 cosocket；timer 回调里可以（resty timer 内 `SCRIPT LOAD` 实测返回 SHA）。
3. `resty.redis` 支持 `script`（LOAD）/ `eval` / `evalsha`。
4. Redis Lua 运行期错误**不回滚已执行的写操作**；NOSCRIPT 属执行前错误，脚本零写入。
5. `redis-cli CLIENT PAUSE <ms>` 可使客户端超时而 Redis 随后完成执行——用于确定性构造"已执行但响应丢失"。
6. Kong 每个 Worker 独立 Lua VM：模块级 Lua table 天然按 Worker 隔离；OpenResty 协程切换只发生在 yield 点（cosocket/ngx.sleep 等）——**不含 yield 的 Lua 同步片段对其他协程不可见交错**，这是本地状态机原子性的边界。
7. 既有资产：策略指纹（`p=`，Phase 1）已是可靠的配置版本标识，可直接充当 pool_key 的配置版本成分；Redis TIME + `elapsed = max(0, now−ts)` 的时间回拨防护（P0-4）已在桶脚本内实现。
8. 事实核查待办（1.2）：OpenResty 是否有原生单调时钟 API（无则采用"软单调"包装，见 D5）；`CLIENT PAUSE` 在本环境可用性。

**架构转向（本期设计的根本变化）**：放弃"聚合库存计数器 + 快照定额减法 + 借位修复"的无锁算术协议，改用**每次 GRANT 创建独立 Lease** 的所有权模型。转向理由（承接评审结论）：

- 聚合余额无法区分库存归属：快照前后的增量、多个 drain 的交错、借位修复与 TAKE 的相互影响都只能靠算术推算，多步 INCR 不是原子事务，"快照后 fill 存活"只能覆盖部分窗口（fill 元数据写与库存写之间的暂停窗口被声明为毛刺）。
- 单一余额无法表达每次 GRANT 的独立生命周期（独立空闲/强制轮换/独立归还）。
- 所有权模型下，正确性边界收缩为两个**可证明**的点：Worker 内"不含 yield 的同步片段"（协程调度保证）与 Redis"单脚本原子"（Redis 串行保证）。不再需要任何补偿算术。

**本期核心原则**：正确性第一，不追求最大化回收率；宁可丢失未使用的本地库存，也不允许重复消费或重复归还；无法证明的保证必须标记为限制。

## Goals / Non-Goals

**Goals:**

- EVALSHA（四脚本统一脚本表；NOSCRIPT 自愈；超时≠NOSCRIPT；不重复扣减）——**已完成（Phase 2）**。
- 单规则 batch>1 的独立 Lease 机制：GRANT 原子创建 Lease、Worker 本地 TAKE、库存耗尽 CLOSED/删除；**V1 无关闭归还流程**（Redis 幂等 RETURN Lua 已实现但 V1 不接入）。
- 性能对比（V1 压缩：M0 复用 Phase 1 + batch=1 严格模式 + batch=10 Lease 模式），真实数据。
- batch=1 与多规则语义零变化；热路径（TAKE）零 Redis 操作。

**Non-Goals（V1，详见 Future Considerations 与 V1 范围裁决节）:**

- **自动生命周期管理（V1 整体 DEFERRED）**：CLOCK_MONOTONIC+FFI、idle scanner、自动 RETURN 调用、max_lifetime 关闭、扫描器重入保护、生命周期配置（lease_return_idle/lease_max_lifetime 不进 V1 schema）。
- Redis Cluster 多 Slot 原子；多规则本地库存；跨 Worker Lease 共享；Worker 故障接管；生产精确消费总账；SIGTERM 可靠归还保证；跨实例本地库存共享；Lease 过期后的库存补偿；复杂分布式库存协调协议；batch 自动调优；复杂预取策略；soak test；生产监控审计。

## Decisions

### D1. EVALSHA 脚本管理（四脚本统一脚本表）

**结构**：模块内 Lua 表 `{ name → { src, sha, loaded } }`（token_bucket / grant_multi / grant_lease / return_lease），独立于 Lease 状态机实现，不框架化。

- 装载：init_worker `ngx.timer.at(0, load_scripts)`；失败 warn 一次不致命；懒加载与 NOSCRIPT 路径同收敛。
- 执行：EVALSHA；**明确的 NOSCRIPT**（错误信息含 NOSCRIPT）→ SCRIPT LOAD → 重试恰好一次；超时**不**进入该路径；连续失败 → 明确错误 → 既有故障分支。
- 不重复扣减论证：NOSCRIPT 为执行前错误，脚本零写入，重试安全；GRANT 路径与 RETURN 路径的恢复分别测试（spec 场景）。
- GRANT/RETURN 的超时语义不同：GRANT 超时 = 结果不明确 = 不重试（D4）；RETURN 超时 = 幂等重试入口（D6）——由调用方语义决定，脚本管理层只透传结果与错误类别（noscript/明确错误/不确定）。

**测试用例**：resty 单测（NOSCRIPT 注入 → 重试计数 =1；超时不触发 LOAD；LOAD 畸形 → 明确错误）；E2E（SCRIPT FLUSH 后分别走 GRANT 与 RETURN 路径，HGET 前后对照不重复扣减）；commandstats（eval=0/evalsha=N）。

### D2. Lease 模型与所有权（Worker 级 Lua table；TAKE 无 yield）

**数据结构**（Worker 级模块表，天然按 Worker 隔离）：

```lua
-- lease.lua 内部（每 Worker 一份）
pools = { [pool_key] = { leases = { lease_obj, ... } } }
lease_obj = {
  lease_id, pool_key,
  granted,          -- Redis 实际授予量（GRANT 返回值）
  remaining,        -- 本地剩余（≥0，take 同步递减）
  consumed,         -- 本地累计消费（账目观测）
  created_at,       -- 授予时刻（诊断用）
  state,            -- V1: "ACTIVE" | "CLOSED"（无 CLOSING 归还态）
}
-- V1 删除（Phase 5 恢复时重新引入）：last_used_at / idle_threshold / max_lifetime
```

- **TAKE（非 yield 同步片段）**：遍历该 pool 的 ACTIVE Lease，取首个 `remaining > 0` 者：`remaining −= 1; consumed += 1`；无可用 ⇒ NEED_GRANT。（V1 无 last_used_at——无 idle 判定消费者。）检查与递减在同一 Lua 片段内，期间无 cosocket/ngx.sleep/timer 等待 ⇒ 协程调度不会插入（事实 6）——这是原子性的完整证明，不需要补偿路径。
- **所有权**：Lease 对象只存在于创建 Worker 的 table 中；其他 Worker 结构性不可见（不变量 2、10）。
- **与既有代码的冲突（先指出，调整建议见文件修改清单）**：`store.lua`（ngx.shared.DICT 聚合库存）是旧 batch>1 路径的唯一实现，新模型下**整体废弃删除**（不保留两套 L2、不做向后兼容）；`handler.lua` 的 shared-dict 降级告警（Phase 2 D5）随之删除；docker-compose 的 `KONG_NGINX_HTTP_LUA_SHARED_DICT` 注入不再被本插件使用（保留与否交由实现组确认——建议删除并同步 docs）。
- **TAKE 顺序**：按 Lease 插入序取首个有存量者（语义与 LRU/FIFO 无正确性差异；V1 无 max_lifetime 轮换，耗尽的 Lease CLOSED 后留在本地 table 中仅作诊断记录，不参与消费）。
- **多 Lease 并存约束（V1）**：同一 pool_key 可同时存在多个 Lease（各自独立 lease_id）；GRANT 成功后在**不发生 yield 的本地代码段中**登记新 Lease（追加到 leases 列表，**不得覆盖已有 Lease**）；TAKE 遍历可消费 Lease、选有剩余者；检查与递减在同一无 yield 片段。Redis GRANT 已原子扣减全局桶 ⇒ 多 Lease 并存不会重复分配全局库存。

**测试用例**：resty 协议级单测（直接驱动 lease.lua，注入时钟）：TAKE 递减/归零不可再取/多 Lease 并存/关闭后不可消费/CLOSED 不可复活/负库存不可能（结构断言）。

### D3. Lease 状态机与关闭流程（本地先行，Redis 后行）



**V1 耗尽处理（本地先行，同一非 yield 片段）**：

```
1. remaining == 0（TAKE 已无法从该 Lease 取出）⇒ state = "CLOSED"、从 ACTIVE 集合摘除
2. CLOSED 不可复活、不可重复消费；本地 table 中仅作诊断记录（不删除、不归还、不清理 Redis 记录）
3. 后续请求 TAKE 不到 ⇒ NEED_GRANT ⇒ 申请新 Lease（新 lease_id）
```

**Deferred Reference（历史/延期设计，非 V1 实现依据）**——Phase 5 恢复自动归还时按以下完整流程实现：

```
ACTIVE ──(空闲阈值 / max_lifetime 到期)──► CLOSING ──(RETURN 完成)──► CLOSED
```

**关闭流程（步骤 1–6 必须在同一非 yield 片段）**：

```
1. state == "ACTIVE"？否 ⇒ 跳过
2. 达到 idle（idle_threshold > 0 且 idle ≥ idle_threshold）或 age ≥ max_lifetime？
   否 ⇒ 跳过（idle_threshold=0 时跳过 idle 条件，max_lifetime 恒检查）
3. state = "CLOSING"
4. 从 pools[pool_key].leases 摘除本 Lease
5. requested = remaining；remaining = 0
6. （同步片段结束；此后允许 yield）
7. Redis RETURN(lease_id, pool_key, requested)——有限幂等重试（D6）
8. 按结果清理：成功/ALREADY_RETURNED ⇒ CLOSED；LEASE_NOT_FOUND/达重试上限 ⇒ CLOSED+lost 记账
```

- 步骤 3–5 之后，任何并发请求 TAKE 都看不到该 Lease（已摘除）——**不变量 4** 的证明就是协程模型本身：片段内无 yield ⇒ 无交错。
- 步骤 6 之后 Lease 已脱离消费路径，RETURN 的 yield 不影响任何请求；期间新 GRANT 创建独立 Lease B，与 A 完全隔离（不变量 10：不同 Lease 对象、不同 Redis Key）。
- 状态机转换单向；CLOSING/CLOSED 不可消费、不可复活（不变量 3、4）。

**测试用例**：resty 确定性单测（注入时钟 + 直接驱动）——场景 A/B/C（15.5）：TAKE 先于关闭/关闭先于 TAKE/RETURN yield 期间新 GRANT 与新 Lease 消费；关闭流程步骤 1–6 的非 yield 断言（代码审查 + 可注入 yield 探针的测试）。

### D4. GRANT_LEASE Lua（桶扣减与 Lease 创建同脚本原子）

**refill 持久化语义（Phase 3 第一组审查裁决，四脚本对照）**：TOKEN_BUCKET **无条件写回** refill 状态（granted=0 时也 HSET+PEXPIRE）；GRANT_MULTI 因多键全或无语义不足时不写（结构差异，非不一致）；GRANT_LEASE 单键与 TOKEN_BUCKET 同构 ⇒ **不足分支同样写回 refill 后 tokens/ts 并更新桶 TTL**；RETURN_LEASE requested=0 时跳过桶更新（Spec 规定，账目闭合由 RETURNED 标记承载）。wait 契约统一：与 TOKEN_BUCKET 一致，按**扣减后** tokens 计算（部分授予时 wait>0）。桶状态数值合法性：tokens∈[0,capacity]、ts≥0、有限数值、granted 正整数——非法返回明确错误码、不得静默修正、数据不变（GRANT_LEASE/RETURN_LEASE 实施；TOKEN_BUCKET/GRANT_MULTI 为历史已验收路径，差异记录不重构）。**TTL 参数合法性（P1-2 第二轮）**：lease_ttl_ms 与 bucket_ttl_ms 统一规则 = 有限数值 + 正整数 + ≥1 且 <2^53（`is_valid_ttl`）——防 inf 通过 floor 比较（inf==inf 恒真）、1e20 精度丢失（>2^53 后 floor 失真）与超大毫秒值；GRANT_LEASE 两处 TTL 与 RETURN_LEASE 一处全部在任何写之前校验，非法 ⇒ INVALID_ARGUMENT 零写入（无"桶已扣 Lease 未建"/"已标 RETURNED 后续失败"中间态）。

```
KEYS[1] = 桶键      KEYS[2] = kong:rl:lease:{lease_id}
-- 注：{lease_id} 为占位符语法而非 Redis Hash Tag——实际 Key = kong:rl:lease:<lease_id>（无大括号，
--     裸跑矩阵与实现一致）。Cluster 部署时 Lease Key 与桶键的 Slot 一致性属 Deferred（见 Future Considerations 1）。
ARGV = [batch, lease_ttl_ms, lease_id, pool_key]（其余 rate/burst 由桶现状+TIME 推导，同既有脚本）
-- lease_ttl_ms 语义（V1 裁决）：调用方传**固定常量**（数值 Phase 4 实施时确定；仅用于 Lease 元数据过期清理，
--     不代表库存自动归还，不影响 Bucket tokens/refill 与 Worker 本地 TAKE/消费，无隐式补偿/重新授权）。
--     历史公式 max_lifetime+3×timeout+60s 属 Phase 5 延期设计（GRANT_LEASE Lua 原始实现保留不动）。

阶段 0 参数校验（零写入）：batch 正整数；lease_ttl ≥ 1；lease_id/pool_key 非空
阶段 1 状态只读校验：EXISTS(KEYS[2]) ⇒ 错误 LEASE_EXISTS（不覆盖）
        桶键类型 ∈ {none, hash}；hash 时 tokens/ts 为合法数值
阶段 2 写：
  refill（Redis TIME；elapsed = max(0, now−ts)；burst 封顶；ts 不回退）
  granted = floor(tokens) 与 batch 取小（tokens < 1 ⇒ granted = 0）
  granted > 0 ⇒ tokens −= granted；HSET 桶 + PEXPIRE 桶
              HSET lease:{id} (pool_key, granted, status=OPEN, created_at=Redis TIME)
              PEXPIRE lease:{id} lease_ttl_ms
  返回 { granted, tokens, wait }（granted=0 ⇒ 未创建 Lease）
```

- granted ∈ [0, batch]，部分授予允许（与既有"部分领取"语义一致）；granted=0 不创建记录（无库存无 Lease）。
- **Bucket 参数统一（回应"rate/capacity 来源"要求）**：现有 Bucket 只存 tokens/ts（last_refill_time），rate/capacity 由 ARGV 传入——TOKEN_BUCKET/GRANT_MULTI 已是该方案，GRANT_LEASE/RETURN_LEASE **必须沿用同一 ARGV 方案**（由调用方从 conf 推导传入），不得仅凭 tokens 推导 rate 或仅凭时间戳推导 capacity。同 pool_key ⇒ 同策略指纹 ⇒ 同 limit/window/burst ⇒ 三个脚本收到的 rate/capacity **可证明一致**（RETURN 由创建 Worker 发起且 pool_key 校验兜底）。
- **Bucket 语义统一**：refill 公式 `elapsed = max(0, now−ts)`、新桶满桶（tokens=burst）、ts 不回退、浮点 tostring、TTL=2×window——TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE 四脚本同构，独立脚本文件 + 相同测试向量验证（禁止各写一套 refill）。
- **执行阶段残余（如实声明）**：校验后写序列理论可中断且不回滚——桶先扣、记录后建，中断 ⇒ 桶已扣但无记录 ⇒ 库存损失（少发方向）+ alert；不得声称执行阶段零写入。
- lease_id 生成（客户端）：`<hostname>:<worker_id>:<进程内单调计数器>:<随机 hex>`；冲突由脚本 EXISTS 检查兜底（LEASE_EXISTS → 故障分支；生成规则使概率≈0）。
- GRANT 超时：结果不明确 ⇒ 客户端不重试（同 ID/新 ID 均禁止）；若 Redis 已执行 ⇒ Lease 存在但 Worker 无本地副本 ⇒ 该 Lease 库存随记录 TTL 消亡（损失方向）；请求走故障分支。

**测试用例**：双源 diff 空（redis/grant_lease.lua vs 内嵌）；resty 裸跑矩阵——满桶/部分授予/不足/LEASE_EXISTS/类型错误/参数非法（零写入断言）；两 Worker 并发 GRANT 全局额度正确；`CLIENT PAUSE` 构造 GRANT 超时（Redis 已执行）⇒ 客户端不重试、记录与扣减已生效、库存损失记账。

### D5. 时间来源（真单调时钟，强制）

- **本地 idle/age 必须（MUST）使用 Linux `clock_gettime(CLOCK_MONOTONIC)` 语义**：经 LuaJIT FFI 调用（resty.core 已启用 FFI 前提下），封装为可注入接口 `now()`（同时是确定性测试的时钟控制点）。**不得**以 ngx.now()/ngx.update_time() 或 max 包装声称单调（墙上时钟向前跳变无法被 max 捕获）、不得用 Redis TIME 计算本地间隔。
- **Phase 0 核查项**：FFI 可用性、`clock_gettime` ABI/返回值/错误处理、`CLOCK_MONOTONIC` 常量、部署环境（容器内）兼容性。**核查不通过 ⇒ 停止 Lease 生命周期相关实现并报告环境限制**（spec 允许暂停；不得悄悄用不合格时钟顶替）。
- Redis 桶 refill 继续用 Redis TIME + `elapsed = max(0, now−ts)`（P0-4 语义保留，与本地时钟无关）。

**测试用例**：注入时钟单测覆盖——正常单调推进/墙上时钟回拨/墙上时钟向前跳变/单调推进而墙上时钟不变/idle 触发/max_lifetime 触发。

### D6. RETURN_LEASE Lua（幂等提交点先行 + 错误码）

**写顺序（相对上一版设计的实质修正）**：**先写 RETURNED 幂等标记（含 return_requested），后一次 HSET 写入完整 Bucket 状态**。理由：Redis Lua 运行时错误不回滚——若"先加桶后标记"，中断+重试会**再次加桶**（重复归还，违反最高不变量）；先标记后，中断 ⇒ 重试得 ALREADY_RETURNED 不再加桶，差额计入损失（少发方向）。**第 12 步（标记）是幂等提交点**：之后任何失败都不允许再次归还。

**执行流程（校验先于一切写；全部单脚本内，Redis 串行无穿插）**：

```
 1. 参数校验（requested 非负整数 <2^53、lease_id/pool_key 非空、数量正确）⇒ INVALID_ARGUMENT
 2. 读 Lease 记录：不存在 ⇒ LEASE_NOT_FOUND（不得加桶）
 3. status = RETURNED ⇒ 同 requested ⇒ ALREADY_RETURNED；不同 ⇒ RETURN_CONFLICT（读 return_requested 比对）
 4. status ≠ OPEN ⇒ INVALID_LEASE_STATE
 5. pool_key 不匹配 ⇒ POOL_MISMATCH
 6. requested > granted ⇒ INVALID_REQUESTED
 7. 读 Bucket：不存在 ⇒ BUCKET_NOT_FOUND（禁止新桶补偿）；类型/字段非法 ⇒ INVALID_ARGUMENT
 8. 【幂等提交点】HSET lease status=RETURNED, return_requested=requested
 9. requested > 0 ⇒ 计算 refill 后桶状态 → +requested → capacity 封顶
    ⇒ 一次 HSET 写入完整桶状态（tokens/ts；不许拆多字段更新）
10. 按现有策略维护 Bucket TTL（与授予侧一致）
11. 返回 { requested, applied, discarded }（applied+discarded=requested；requested=0 ⇒ applied=discarded=0）
```

- **错误码表**：SUCCESS / ALREADY_RETURNED / RETURN_CONFLICT / LEASE_NOT_FOUND / INVALID_LEASE_STATE / POOL_MISMATCH / INVALID_REQUESTED / BUCKET_NOT_FOUND / INVALID_ARGUMENT（命名可按项目风格统一，语义不变）。
- **残余写入语义（如实声明）**：提交点后桶更新失败 ⇒ RETURNED 已定、桶未加 ⇒ 损失（少发）；不得声称执行阶段零写入。校验失败 ⇒ 零写入。
- **requested=0**：跳过桶更新，仍完成 OPEN→RETURNED（账目闭合）。
- **Bucket 不存在**：禁止新桶补偿/禁止按旧策略参数推测 ⇒ 损失。

**RETURN 重试策略**：仅对结果不明确（超时/连接中断）以**原 lease_id + 原 requested** 重试，总计 ≤3 次尝试（含首次），尝试间短暂 sleep；明确错误不重试；ALREADY_RETURNED = 成功终态；达上限 ⇒ CLOSED + lost。

**测试用例**：裸跑矩阵——正常/重复同参（ALREADY_RETURNED 桶不增）/同 ID 异参（RETURN_CONFLICT）/并发两 RETURN（桶只加一次）/requested=0/>granted/Lease 过期（LEASE_NOT_FOUND）/**Bucket 过期（BUCKET_NOT_FOUND 零写入）**/标记后桶失败注入（重试不重复归还）；E2E `CLIENT PAUSE` 超时 ⇒ 幂等重试且桶只加一次。

### D7. 配置变更与 pool_key（指纹复用；生命周期参数快照进 Lease）

- `pool_key` = 既有桶键（含 `p=<策略指纹>` 配置版本成分 + 维度值）——指纹已覆盖 limit/window/burst/limit_by/header_name，即全部额度语义配置 ⇒ 配置变更 ⇒ 新 pool_key ⇒ 新 Lease，天然隔离（不变量：新配置不消费旧 Lease）。
- `lease_return_idle` / `lease_max_lifetime` **不在指纹内且不进 V1 schema**（生命周期参数 V1 DEFERRED）：Phase 5 恢复时才引入，届时通过 Lease 创建时快照实现隔离（无需 first-writer-wins/冲突告警——所有权已按 Worker 隔离）。
- batch 变更：batch 不在指纹内；batch 变更后的新 GRANT 以新 batch 授予，既有 Lease 按其 granted 消费/归还——账目不受影响。

**测试用例**：配置变更 E2E（改 limit ⇒ 新 pool_key 新 Lease，旧 Lease 按快照关闭；改 idle/max ⇒ 既有 Lease 用旧阈值，新 Lease 用新值）。

### D8. 指标与账目观测

- **Worker 本地计数器 + 结构化日志**（notice）：lease_granted/consumed/return_requested/return_applied/return_discarded/return_failed/return_duplicate/active/closed/local_remaining 口径（§14.1 命名）；TAKE 热路径零 Redis 操作（计数为本地变量）。Prometheus 暴露留 Phase 5（Deferred）；本期以日志 + resty 可调用的 `lease.stats()` 供测试与报告取证。
- **确定性账目（V1 口径）**：正常运行 `granted = consumed + outstanding`（outstanding = Σ本地 remaining）；Worker 崩溃后 `granted = consumed + lost`（lost = 无法继续消费的剩余授权库存）。`returned_applied` 非 V1 正常账目组成部分（RETURN Lua 已实现、V1 不接入；恢复自动归还时重新引入）。桶当前 tokens 因 refill/封顶**不能**直接当总账——测试只对明确 Lease 集合统计。

**测试用例**：确定性序列账目闭合（grant 100/consume 80/return 20 ⇒ 恒等式）；封顶丢弃场景（discarded 计 lost）。

## 正确性不变量（Spec 同款，逐条给出证明边界）

| # | 不变量 | 证明边界 |
|---|---|---|
| 1 | 全局授予不超额 | GRANT Lua 单脚本原子扣桶（Redis 串行） |
| 2 | Lease 唯一归属 | Worker 级 table 结构性隔离（每 Worker 独立 Lua VM） |
| 3 | 本地库存不为负 | TAKE 非 yield 同步片段 + 无补偿路径（代码审查断言） |
| 4 | 关闭后不可消费 | V1：耗尽即 CLOSED/摘除（本地先行）；（Phase 5 恢复时：CLOSING+摘除在 RETURN 的任何 yield 之前完成） |
| 5 | 每 Lease 至多 RETURN 一次成功 | Redis OPEN→RETURNED 单脚本原子转换；重复 ⇒ ALREADY_RETURNED |
| 6 | 0 ≤ requested ≤ granted | 关闭时 requested=remaining ∈ [0, granted]（remaining 单调非负、granted 为初值）；Redis 端校验拒绝越界 |
| 7 | 结果不明确不制造新额度 | GRANT 不重试；RETURN 仅原 ID+原 requested 幂等重试 |
| 8 | Worker 崩溃只损失库存 | 无跨 Worker 补偿路径（结构性不存在）；OPEN 记录 TTL 消亡 |
| 9 | Lease 记录不提前过期 | V1：固定 lease_ttl 常量（Phase 4 定值）；（Phase 5 恢复时：公式覆盖 max_lifetime+重试窗口+余量，D6） |
| 10 | 不同 Lease 相互隔离 | 独立对象 + 独立 Redis Key；TAKE/关闭/RETURN 只触自身 |

## Risks / Trade-offs

- **库存回收率下降**：所有权模型下，Worker 崩溃/GRANT 超时/记录过期的损失不可补偿（设计选择：正确性优先）。损失上界 = 单 Worker 未关闭 Lease 的 remaining 之和 ≤ 每池 batch × 活跃 Lease 数；报告量化。
- **每 GRANT 一个 Lease ⇒ Redis 记录数 = GRANT 次数**：高 GRANT 频率（每 batch 次请求 1 个）下记录数量 = 请求量/batch，TTL 有界 ⇒ 存量有界（≈ 活跃 Lease 数 + RETURNED 保护窗口内的记录数）；HGETALL 不再需要（按 lease_id 直取）。报告评估实际规模。
- **RETURN 重试引入新的失败面**：有限重试（≤2）只对不确定错误；重试风暴风险由上限约束。
- **软单调时钟**：回拨保护不完美（长暂停跨回拨仍可能误判）——影响仅 idle/age 判定偏差（关闭时机），不影响账目；原生单调 API 若存在则替换（1.2 核查）。
- **执行阶段残余写入**：GRANT/RETURN Lua 校验后写序列理论可中断且不回滚 ⇒ 方向均为少发（桶已扣无记录 / 桶已加未转状态）+ alert；不得声称零写入。
- **store.lua 删除的回归面**：batch>1 路径整体重写——Phase 1/2 锚点（batch 基线、故障双路径）须以新实现复测并在报告注明锚点变化原因。
- **矩阵噪声**（容器环境）：如实标注；不做多轮中位数。
- **EVALSHA 对比可能显示提升有限**：目的是确认有效性，如实记录。

## Future Considerations / Deferred Items

### 1. Redis Cluster 支持
背景：GRANT/RETURN Lua 同时操作桶键与 lease 键，可能跨 slot。限制：本期仅 standalone；文档不宣称支持 Cluster。风险：误配 ⇒ 多键 EVAL 报错（fail-closed，不错账不可用）。方向：lease 键并入桶 hash tag / 独立登记服务。

### 2. 精确生产消费总账
背景：Worker 崩溃后本地 remaining 不可恢复；GRANT/RETURN 超时不可区分。限制：仅确定性测试窗口精确；生产保守上界。风险：承诺精确而实现达不到 ⇒ 信任损害。方向：持久化消费计数（RETURN 携带 consumed 增量入记录）、节点级对账。

### 3. Worker 故障接管
背景：Worker 崩溃 ⇒ 其 Lease 库存损失。限制：不做跨 Worker 补偿/接管/选主。风险：损失随崩溃频率累积（少发）。方向：Lease 记录心跳 + 接管协议（独立设计）。

### 4. SIGTERM 可靠归还
背景：退出期 timer 行为未证实。限制：仅 best-effort exiting 轮询。风险：重启损失 ≤ 本 Worker remaining 和。方向：信号处理器/外部 drain 钩子；先以数据说话。

### 5. 多规则本地库存（β）
背景：多规则 α 模式每请求 1 RTT。限制：本期不实现。风险：无（行为与 Phase 3 一致）。方向：多 Lease 联合授予与归还协议（独立 change）。

### 6. GRANT 幂等
背景：GRANT 超时损失库存。限制：本期不做 GRANT 幂等（结果不明确不重试）。风险：GRANT 超时率高的部署库存损失放大。方向：lease_id 预注册（SET NX）+ GRANT 幂等语义（独立 change）。

## Migration Plan（对齐实施规范 Phase 0–8，每阶段独立 commit）

0. **Phase 0 代码现状审查**（不修改生产代码）→ `docs/PHASE0_REVIEW.md`：现有架构/Bucket 字段与参数来源/EVAL 路径/多规则实现/与规范差异/冲突与风险；有阻塞性不兼容 ⇒ 暂停编码先报告。
1. **Phase 1 EVAL 基线**：补齐基线测试并运行 → results.md 第一版（`test: add phase4 eval performance baseline`）。
2. **Phase 2 EVALSHA**：统一脚本注册/LOAD/EVALSHA/NOSCRIPT 恢复/四脚本验证/回归 + 第二组性能（`feat: add evalsha script management`）。
3. **Phase 3 Redis Lease 数据模型**：Lease Key/字段/GRANT_LEASE/RETURN_LEASE（幂等提交点先行）/TTL/校验与幂等测试；不接请求路径（`feat: add redis lease grant and return scripts`）。
4. **Phase 4 Worker 本地 Lease**：Worker table/状态机/TAKE/GRANT 调用/剩余维护/唯一关闭流程；不接扫描器，先单测（`feat: add worker local lease manager`）。
5. **Phase 5 Lease 生命周期**：单调时钟/idle/max/每 Worker 扫描器/重入保护/RETURN 有限重试/配置快照与隔离（`feat: add lease lifecycle and idle return`）。
6. **Phase 6 请求路径集成**：batch=1 保持/batch>1 接入/多规则保持/故障与 429/503 行为/配置兼容/端到端回归（`feat: integrate worker lease into rate limit path`）。
7. **Phase 7 性能测试与报告**：第三组测试/三组对比/库存损失与限流误差/NOT RUN 标注（`test: add phase4 lease performance report`）。
8. **Phase 8 清理**：仅当全部测试通过——删除 store.lua 聚合实现/shared dict 状态/重复路径/过时配置，更新 README（`refactor: remove legacy local inventory implementation`）。
9. 回滚：阶段级 commit revert；batch=1 路径全程不动提供兜底语义。

## 验收标准（对齐 §17 的 21 条）

| # | 验收项 | 证据 |
|---|---|---|
| 1 | EVALSHA + NOSCRIPT 自愈（GRANT/RETURN 分别验证） | SCRIPT FLUSH 后 HGET 对照 + commandstats |
| 2 | batch=1 与既有严格路径一致 | quota.sh batch=1 基线 100/350/0 + 故障双路径 |
| 3 | 单规则 batch>1 使用独立 Lease | Redis lease 记录可见、状态 OPEN→RETURNED |
| 4 | 每 Lease 单一 Worker 所有者 | 多 Worker 测试（A/B 互不可见互不代管） |
| 5 | TAKE 无负库存 | 协议级单测 + 结构断言（无补偿路径） |
| 6 | TAKE 无 yield 点 | 代码审查 + 可注入 yield 探针测试 |
| 7 | 关闭后不可消费 | 状态机单测（场景 A/B/C） |
| 8 | 空闲超时关闭 | 注入时钟单测 + E2E |
| 9 | 最大生命周期强制关闭 | 注入时钟单测（持续消费 Lease）+ E2E |
| 10 | GRANT 原子创建 Lease 记录 | 裸跑矩阵 + 失败无"扣桶无记录"成功返回 |
| 11 | RETURN 原子更新桶与状态 | 裸跑矩阵 + 无 OPEN 中间态断言 |
| 12 | 重复 RETURN 不重复加桶 | 幂等单测 + E2E |
| 13 | RETURN 超时同参重试安全 | CLIENT PAUSE 两分支 + 重试计数断言 |
| 14 | GRANT 结果不明确不盲目重试 | CLIENT PAUSE + 重试计数 =0 断言 |
| 15 | Worker 崩溃只损失库存 | kill -9 确定性账目（granted−consumed−returned=lost） |
| 16 | TAKE/RETURN 并发测试通过 | 场景 A/B/C 确定性测试 |
| 17 | 多规则原子扣减无回归 | rules.sh 全绿 |
| 18 | 新旧配置 Lease 隔离 | 配置变更 E2E |
| 19 | Lease TTL 覆盖公式 | PTTL 断言 + OPEN 过期 RETURN 拒绝测试 |
| 20 | 性能报告真实数据 | results.md + NOT RUN 标注 |
| 21 | 每阶段测试结果与独立 commit | git log + 各组报告段 |

验收纪律：FAIL 即停；无 NOT RUN 或如实标注；锚点变化必须注明原因（batch>1 路径重写属预期变化）；报告不得声称未实现的保障（精确总账/Cluster/SIGTERM 保证/fencing）。

## Open Questions

（无阻塞项。1.2 核查：原生单调 API 有无（有则替换软单调）；1.3 SIGTERM 分支；store.lua 删除与 compose shared-dict 清理的执行确认——建议删除，由实现组在 Phase 4.5 执行。）
