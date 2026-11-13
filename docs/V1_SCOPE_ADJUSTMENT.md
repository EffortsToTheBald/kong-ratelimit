# V1 范围收缩变更报告（Phase 4～8 SDD 计划调整）

> 执行依据：V1 交付范围收缩指令（2026-11-13）。
> 本轮**只修改 SDD 文档，未修改任何业务代码/Lua 脚本/测试实现，未创建 commit**。

## 1. 仓库状态

- 分支：master；**修改前 HEAD = `e1155b5`**（工作区干净）；修改后 HEAD 不变（本轮不 commit）。
- Phase 0～3 提交逐一核实在位：`17cfe37`（Phase 0 审查）、`8b04976`（Phase 1 基线）、`e4dd6c8`+`b700417`（Phase 2 EVALSHA）、`d53f3f0`+`d30592b`+`e1155b5`（Phase 3 Lease 数据模型，矩阵 50 项）。
- README.md / rule.md / docs/design.md（项目交付文档）**均无** lease 生命周期相关描述（grep=0）——生命周期内容仅存在于 Phase 4 change 的 SDD 内，无需清扫项目级文档。

## 2. 文件变更

| 文件 | 变更 |
|---|---|
| `openspec/.../specs/rate-limiting/spec.md` | 6 处 Requirement 加 V1 裁决/边界注记：①Lease 模式适用边界（归还行为=Phase 5 恢复项）②所有权与状态机（简化 ACTIVE→CLOSED）③生命周期管理（**DEFERRED**）④⑤RETURN 两条（Lua 已实现、V1 不接入调用）⑥账目边界（V1 无 RETURN ⇒ lost=全部未消费）。4 条超长描述压缩（`--strict` 零 issue） |
| `openspec/.../design.md` | 新增「V1 范围裁决」节（置于 Context 前）；Goals/Non-Goals 改写为 V1 口径（自动生命周期整体 DEFERRED 并列明 13 项延期清单）；D3/D5/D6 加 V1 边界标注（D3 简化状态机、D5 时钟 DEFERRED、D6 Lua 已实现不接入）；Migration Plan 重写为 V1 版（Phase 0–3 标已完成、Phase 4 简化版/Phase 5 DEFERRED/Phase 6 核心/Phase 7 压缩/Phase 8 清理） |
| `openspec/.../tasks.md` | Phase 4 重写（4.3 耗尽处理简化、4.1 字段删阈值/时钟、无扫描器）；Phase 5 全部任务加【DEFERRED】标注并声明"不得合并进 4/6"；Phase 6 重写（删扫描器/SIGTERM/关闭交错，加配置隔离核对与 V1 口径 E2E）；Phase 7 压缩（正确性 11 项 + 三点性能 + 矩阵证据核对）；Phase 8 加最终交付文档与 Production TODO 清单（13 项延期标注"未实现"） |
| `openspec/.../proposal.md` | 顶部加「V1 范围裁决」节 |
| 无删除文件 | — |

**未修改**：业务代码、Lua 脚本、测试脚本、bench、docs/PHASE*_REPORT、README、rule.md（Phase 8 交付文档更新留待清理阶段）。

## 3. 范围调整

| 项 | 处理 | 原因 |
|---|---|---|
| Phase 4 Worker 本地 Lease | **保留，简化**：TAKE/GRANT 接线/多 Worker 隔离/耗尽处理全保留；删除关闭归还流程（CLOSING/RETURN 调用/快照）、生命周期阈值字段、时钟注入 | 自动归还非原题要求；耗尽即损失是保守安全方向 |
| Phase 5 生命周期 | **整体 DEFERRED**（Clock/FFI、扫描器、idle/max、配置快照、RETURN 重试策略） | 不是原题核心交付；省去 FFI 适配/定时器并发/恢复逻辑 |
| Phase 3 RETURN_LEASE Lua | **保留不删不改**（50 项矩阵已验收）；**V1 请求路径不接入调用** | 已完成的 Redis 数据模型能力；未来库存回收直接复用 |
| Phase 6 集成 | **保留，V1 核心**：删扫描器启动/SIGTERM/关闭交错；加配置隔离核对；回归全保留 | 原题核心逻辑 |
| Phase 7 测试 | **压缩**：正确性 11 项 + M0/batch=1/batch=10 三点 + Phase 3 矩阵证据核对（不重跑 50 项全矩阵） | 证明核心价值即可；Phase 3 矩阵已是确定性证据 |
| Phase 8 清理 | **保留** + 最终交付文档（架构图/流程图 ×3/Production TODO 13 项标注"未实现"） | 原题要求的取舍说明与交付物 |

## 4. 一致性检查（指令 §九 Step 4 的 15 项）

| # | 检查 | 结果 |
|---|---|---|
| 1 | Spec 与 Design 一致 | ✓ 两者的 V1 裁决注记一一对应（状态机/生命周期/RETURN/账目） |
| 2 | Design 与 Tasks 一致 | ✓ Phase 4/5/6/7/8 任务与 Design 的 V1 边界一致 |
| 3 | Phase 编号连续无重复 | ✓ 保留 0–8 编号；Phase 5 标 DEFERRED 不制造空任务 |
| 4 | V1 必做与 Production TODO 分离 | ✓ Design Non-Goals/Tasks Phase 8.2 双处列明 13 项延期 |
| 5 | CLOCK_MONOTONIC 遗留 | ✓ 仅存在于生命周期 Requirement（DEFERRED 标注内）与 Design D5（V1 边界标注） |
| 6 | idle scanner 遗留 | ✓ 同上（生命周期 Requirement DEFERRED 内；Tasks Phase 5 全部【DEFERRED】） |
| 7 | 自动 RETURN 遗留 | ✓ Spec 两条 RETURN Requirement 的 V1 边界注记明确"V1 不接入调用"；Tasks Phase 4/6 无 RETURN 任务 |
| 8 | RETURN Lua ≠ 自动归还 | ✓ Spec/Design/Tasks 三处均明确区分（"Lua 已实现；V1 不接入调用"） |
| 9 | batch=1 严格模式保留 | ✓ Spec/Tasks 6.1"一行不动" |
| 10 | batch>1 Lease 模式保留 | ✓ Spec/Tasks 6.1 |
| 11 | 多规则原子扣减保留 | ✓ Spec/Tasks 6.1"一行不动"，且多规则不产生 Lease |
| 12 | Fail-close 保留 | ✓ Tasks 6.2 故障分支核对 |
| 13 | 429+Retry-After 保留 | ✓ Spec（既有）+ Tasks 7.1-⑩ |
| 14 | 多维度限流保留 | ✓ Phase 1/3 已验证，dims.sh 回归保留（6.4/7.1） |
| 15 | 多 Worker 正确性测试与性能测试保留 | ✓ Tasks 4.5/6.5/7.1-⑦⑧/7.2 |

`--strict` 校验：**零 issue**。

## 5. 测试情况

本轮为纯文档调整，**未运行任何业务测试（NOT RUN）**——无测试结果可伪造或遗漏。既有测试证据（Phase 2 8/8、Phase 3 矩阵 50/0）不受影响。

## 6. 后续实施建议（调整后的顺序）

1. **Phase 4（Worker 本地 Lease，简化版）**：4.1 结构 → 4.2 TAKE → 4.3 耗尽处理 → 4.4 GRANT 接线 → 4.5 多 Worker 隔离 → 4.6 commit。预计比原计划少 40% 工作量（无时钟/关闭归还/快照）。
2. **Phase 6（请求路径集成）**：6.1 接线 → 6.2 故障语义 → 6.3 配置隔离 → 6.4 全量回归 → 6.5 并发异常 E2E → 6.6 commit。
3. **Phase 7（验证）**：7.1 正确性 11 项 → 7.2 三点性能 → 7.3 矩阵证据核对 → 7.4 报告 → 7.5 commit。
4. **Phase 8（清理交付）**：8.1 删 store.lua → 8.2 交付文档+Production TODO → 8.3 commit。
5. Phase 5 不排期；Phase 5 恢复 = Production TODO 中"idle 自动归还 + 生命周期管理"独立立项。

## 7. 风险和待确认事项

1. **`remaining+consumed=granted` 守恒账目在 V1 缺"returned"项**：V1 无 RETURN ⇒ 账目简化为 `granted = consumed + lost`。Spec 账目 Requirement 已加 V1 边界注记；**风险**：如果审查方仍期望账目含 returned 项，需确认 V1 口径可接受（本口径数学上等价：returned 恒 0，未消费全部计入 lost）。
2. **Phase 3 RETURN_LEASE Lua 成为"未接线代码"**：已实现并验证但不被任何请求路径调用——**代码覆盖工具可能标记为死代码**（Phase 8 清理时注意：**不得删除**，它是 Production TODO 的已实现资产）。
3. **`lease_ttl_ms`/`bucket_ttl_ms`/`granted` 等 GRANT_LEASE 参数在 V1 的取值**：无生命周期配置 ⇒ `lease_ttl_ms` 需要一个固定值（建议 Phase 4 实现时定常量，如 3600000=1h，仅作为 Redis 记录清理周期，不影响正确性）——**Phase 4 实施时需确认**。
4. **Redis 记录累积**：V1 无 RETURN/无回收 ⇒ Lease 记录（TTL 后过期）在 crashed Worker 场景下依赖 TTL 清理；高频 GRANT 下记录数量需在 Phase 7 观测（已列入 7.2 采集项）。
5. **Phase 1 基线的可比性**：Phase 1 数据为 Legacy 聚合库存实现；Phase 7 的 batch=10 数据与之对比时**必须注明实现不同**（Phase 1 基线仅作负载量级参照，不做逐 ms 对比）。
6. **设计裁决未决项**：无——开工核对的三项裁决（阶段映射/Lease Key/字段名）已由上轮确认落地。
