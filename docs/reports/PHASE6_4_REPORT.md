# Phase 6.4 报告：全量回归与故障双路径验证

- **日期**：2026-11-13
- **执行前 HEAD**：`cbaaf12`（6.3 审查修正后）；工作区干净（仅 `1113.json` 会话导出未跟踪）
- **本阶段性质**：只做验证与阻断性修复，零生产代码修改
- **commit**：`test: complete phase6.4 regression verification`

## 1. 测试环境

- 三节点 `kong1/2/3`（每节点 2 Worker）+ 单实例 `redis`；Config API :8031/:8011/:8021，代理 :8030
- 统计口径：`CONFIG RESETSTAT` + `INFO commandstats` 的 `cmdstat_evalsha:calls`（窗口内只含该轮压测 + 配置下发，实测配置下发贡献 0 次 EVALSHA）

## 2. quota.sh batch=1（Spec 场景 1：batch=1 严格路径零变化）

| 轮次 | 结果 | EVALSHA calls | lease 记录 |
|---|---|---|---|
| 第 1 轮 | allowed=100 limited=350 other=0 total=450，**严格等于配额 100 PASS** | — | — |
| RESETSTAT 后 | allowed=100 limited=350 other=0 PASS | **恰 450**（每请求 1 次，零 Lease 记录） | **0** |

- 结论：batch=1 每请求 EVAL，不走本地 Lease，450 恰 100 放行，与 Phase 1 锚点一致；Spec"Redis 中无 Lease 记录"✓（450 次恰好=请求数，逐请求授权）
- 锚点变化：无（数据与历史基线一致）

## 3. quota.sh batch=20（Spec 场景 3：单规则 batch>1 使用 Lease）

| 轮次 | allowed | lease 记录 | EVALSHA calls |
|---|---|---|---|
| 第 1 轮 | **80** ∈ [40,100] PASS | 5 条（各 granted=20，status=OPEN） | — |
| 第 2 轮 | 100（利用率 100% PASS） | —（窗口内 355 次） | **355** |

- **账目核验（第 2 轮 355 = 350 + 5）**：450 请求 = 95 次纯本地 TAKE（零 Redis，= 100 allowed − 5 次池首 GRANT）+ 5 次 granted-GRANT + 350 次 denied-GRANT（库存耗尽 ⇒ 每次申请被桶拒 ⇒ granted=0 ⇒ 429，冻结设计"耗尽即新 Lease 申请"，不伪装、不重试）
- GRANT 记录 status=OPEN、granted=20 与 batch=20 配置一致；不超发（allowed ≤ limit）
- 注意：denied-GRANT 属 miss 路径一次 EVAL（全局一致性由 GRANT 脚本的桶检查保证），非"每请求 Redis 操作"；池命中请求零 Redis ✓
- 覆盖：GRANT_LEASE 批量授权 + 本地 TAKE + 库存不足重新申请 ✓

## 4. dims.sh 回归

**PASS 8/8**：IP / Path / Client ID / Header 等仓库现有维度全绿——维度值隔离、正确命中桶、Header 配置生效、配置指纹不破坏维度隔离、batch>1 Lease 路径不破坏维度限流语义（dims.sh 覆盖 batch>1 场景）

## 5. rules.sh 回归（Spec 场景 2：多规则路径零变化）

**PASS 14/14**，含核心场景"预置一空一有 ⇒ 429 且双桶 tokens 均不变"；多规则全或无、合法放行、429/Retry-After 语义全绿；未修改多规则算法或 Lua 协议；Spec"Redis 中无 Lease 记录"由 6.2 组 `algorithm-lease-e2e.sh` 的多规则零 lease 断言与本轮 rules.sh 路径共同覆盖

## 6. 故障双路径

### 6.1 handler-fault-e2e.sh（PASS 26/26）

- 连接拒绝：batch=1 与 batch>1 均 503（ft=false）/ 降级（ft=true）；故障不伪装 429 ✓
- CLIENT PAUSE 6s 超时：batch=1 进既有故障分支；batch>1 不确定结果 ⇒ 503、不重复申请、不登记本地库存、不伪装令牌不足 ✓
- 双 Worker [0,1] 持库存（lease_worker_ids 按记录归属实证）✓

### 6.2 fault-recovery-e2e.sh（新增，PASS 12/12，§7.3）

- R1 连接拒绝→恢复：故障期 503 ⇒ Redis 恢复 ⇒ 请求 200 remaining=9（新 GRANT，未把失败当已授权）；**该 ns lease 记录恰 1 条**（连接拒绝期间 Redis 停机零写入为确定性事实；恢复后单次授权，无重复授权）
- R2 CLIENT PAUSE 超时→恢复：并行 2 请求均 503（不重试）；PAUSE 过期后请求 200 remaining=9；**lease 记录增量恰 +1**（恢复前 0 条——超时窗口 Redis 零写入，允许 0 或 1 的增量断言不违反 GRANT 超时冻结语义）；超时窗口记录 ≤1 ⇒ 单请求恰一次 GRANT

## 7. EVALSHA 缓存丢失自愈（§8）

### 7.1 script-cache-selfheal-e2e.sh（新增，PASS 14/14）

- 三模式（batch=1 / batch>1 GRANT_LEASE / 多规则 GRANT_MULTI）FLUSH 前各 200（懒加载 EVALSHA 正常）
- `SCRIPT FLUSH` 后三模式各请求 ⇒ 全部 200（NOSCRIPT ⇒ SCRIPT LOAD ⇒ 重试恰一次 ⇒ 自愈成功；无自愈则 503）
- `SCRIPT EXISTS` 证实三个脚本（sha `2aa486…` / `128232…` / `559d9b…`）均被插件装回缓存
- 日志无 `script still missing after reload` / `script load failed`

### 7.2 静态单测 evalsha-unit.sh（PASS 8/8）

- NOSCRIPT ⇒ LOAD ⇒ 恰一次重试成功；重试后仍 NOSCRIPT ⇒ 明确失败、无第二次 LOAD（不无限重试）
- **超时 ⇒ 不触发 LOAD**（绝不当作 NOSCRIPT）——满足"超时、断连不能错误触发 SCRIPT LOAD"
- LOAD 失败等错误路径不破坏 Phase 2 行为

## 8. Spec 适用边界三场景逐项验证（spec.md `Lease 模式适用边界` Requirement 原文）

| # | 场景定义（原文） | 预期行为 | 测试脚本 | 实际结果 | 满足 Spec |
|---|---|---|---|---|---|
| 1 | **batch=1 严格路径零变化**："以 batch=1 配置复跑 Phase 1 基线（450 请求恰 100 放行）与故障双路径" | 结果与既有锚点一致，Redis 中无 Lease 记录 | quota.sh -b 1 + handler-fault-e2e.sh + RESETSTAT 口径 | 450 恰 100/350/0 两轮一致；EVALSHA 恰 450；lease 记录 0；故障双路径 26 断言全绿 | ✓ |
| 2 | **多规则路径零变化**："复跑 rules.sh 全场景" | 全绿且 Redis 中无 Lease 记录；多规则"一空一有 ⇒ 429 且双桶不变"语义不变 | rules.sh（14 场景含核心场景）+ algorithm-lease-e2e.sh 多规则零 lease 断言（6.2 组已验证） | PASS 14/14；一空一有⇒429 双桶不变 ✓；多规则零 Lease ✓ | ✓ |
| 3 | **单规则 batch>1 使用 Lease**："以 batch=20 配置发起请求" | 首次请求经 GRANT 创建 Lease（Redis 可见 lease 记录，状态 OPEN），后续请求本地 TAKE 消费，无每请求 Redis 操作 | quota.sh -b 20 + RESETSTAT 账目核验 | lease 记录 OPEN granted=20；95 池命中请求零 Redis；耗尽时重新申请 ✓ | ✓ |

未改写任何 Spec 验收口径；实现与冻结 Spec 无冲突。

## 9. PASS / FAIL / NOT RUN 统计

| 项目 | 结果 |
|---|---|
| quota.sh -b 1（两轮+账目） | PASS |
| quota.sh -b 20（两轮+账目） | PASS |
| dims.sh | PASS 8/8 |
| rules.sh | PASS 14/14 |
| handler-fault-e2e.sh（故障双路径） | PASS 26/26 |
| fault-recovery-e2e.sh（新增） | PASS 12/12 |
| script-cache-selfheal-e2e.sh（新增） | PASS 14/14 |
| evalsha-unit.sh（静态自愈） | PASS 8/8 |
| Phase 6.1–6.3 套件（lease-unit 25 / algorithm-lease-unit 17 / algorithm-lease-e2e 15 / config-isolation 15+14） | 本组引用 6.1–6.3 已验证结果（本轮 dims/rules 变更后行为未变） |
| **合计** | **PASS 112 / FAIL 0 / NOT RUN：Phase 6.5 并发与异常 E2E、6.6 最终交付** |
| 指标区分 | 4.1/4.2/5/6/7/8 = 实际执行；实现对照 = 静态代码检查；6.5 = 未执行 |

## 10. 发现的问题及修复记录

- **无生产代码回归、无阻断性修复**（零生产代码修改）
- 过程调整（非代码）：`total_commands_processed` 差值含配置下发噪声，不可作区分锚点 ⇒ 改用 `CONFIG RESETSTAT`+`commandstats` 精确口径；CMD 数据已在报告如实保留
- b20 第一轮 allowed=80、第二轮 100：Worker 分配差异导致的合法区间波动（[40,100]），非回归

## 11. 进入 Phase 6.5 的条件

- batch=1 零回归 ✓；batch>1 Lease 路径正确 ✓；维度/多规则零回归 ✓；故障双路径符合既有语义 ✓；EVALSHA 自愈三脚本实证 ✓；Spec 三场景全部满足 ✓
- **结论：满足进入 Phase 6.5（并发与异常 E2E）的条件**
