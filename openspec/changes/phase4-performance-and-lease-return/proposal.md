# Proposal

## Why

Phase 3 归档后，正确性基线（Phase 1）、多维与语义（Phase 2）、多规则联合判定（Phase 3）已闭环。距离"Ready for Production"还剩两类明确记录的短板：

1. **性能与脚本执行效率**：每次 EVAL 全量上传脚本文本；design.md §8 的性能 ⟨TODO⟩ 无数据支撑。
2. **库存生命周期**：单规则 batch>1 模式下，节点重启/下线丢失本地库存（少发方向），且"聚合库存计数器 + 快照/借位修复"协议无法可靠区分库存归属——多步 INCR 非原子事务、快照前后增量不可分、借位修复与 TAKE 补偿相互影响。

本期采用**所有权模型**重构本地库存：Redis 全局令牌桶为唯一权威，每次 GRANT 在同一 Lua 脚本内原子扣桶并创建**独立 Lease 记录**（唯一 lease_id、status=OPEN/RETURNED）；Worker 以 Worker 级 Lua table 独占自己的 Lease 并本地消费（TAKE 不访问 Redis、无 yield 点、无负库存）；Lease 具备空闲超时与最大生命周期双关闭条件（单调时钟、创建时配置快照）；Redis RETURN 通过 OPEN→RETURNED 原子状态转换实现**幂等**（同 lease_id + 同 requested 重试安全，ALREADY_RETURNED 不重复加桶）。正确性边界收缩为两个可证明点：Worker 内非 yield 同步片段（协程调度）与 Redis 单脚本原子——不再依赖任何补偿算术。

## What Changes

- **EVALSHA**：四脚本统一脚本表（TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE）；timer 延迟加载 + 懒加载；明确 NOSCRIPT → LOAD → 重试恰一次；超时不得当作 NOSCRIPT；GRANT 与 RETURN 自愈路径分别验证。
- **Redis Lease 数据模型**：`lease:{lease_id}` 独立 Key（status OPEN/RETURNED、granted、pool_key、created_at）；GRANT Lua 原子完成 refill/扣桶/建记录（部分授予允许、tokens<1 不建记录、同 ID 冲突拒绝）；RETURN Lua 三阶段（参数校验/只读校验/写）幂等，返回 requested/applied/discarded（capacity 封顶丢弃计丢失）；Lease TTL 覆盖 max_lifetime + RETURN 重试窗口 + 余量。
- **Worker 本地 Lease**：`lib/lease.lua`（Worker 级 table）——take（非 yield 同步片段）、状态机 ACTIVE→CLOSING→CLOSED（单向）、关闭流程本地先行（摘除后才允许 RETURN 的 yield）；每 Worker 1s 扫描器 + 重入保护；单调时钟（软单调包装 + 首日核查原生 API）。
- **生命周期**：`lease_return_idle`（默认 10s，0–3600，0=关空闲触发）+ `lease_max_lifetime`（默认 300s，10–3600，强制轮换不可关）；二者以创建时快照写入 Lease，配置变更不追溯。
- **超时语义**：GRANT 结果不明确 ⇒ 不重试、允许损失；RETURN 结果不明确 ⇒ 仅原 ID + 原 requested 有限幂等重试（≤2 次），达上限允许损失。
- **性能矩阵**：EVAL 基线先行 + EVALSHA 复测；batch 1/10/50/100 × 速率 × Worker 数 × 单/多规则 × RETURN 开关 × Redis 故障恢复；真实数据、NOT RUN 如实标注。
- **保持原有限流语义**：batch=1 严格路径与多规则原子路径一行不动；Lease 机制对其 no-op。

## Capabilities

### Modified Capabilities

- `rate-limiting`：新增 8 条 ADDED 需求（EVALSHA 脚本管理、性能基线测量、Lease 适用边界、Lease 所有权与本地状态机、Lease 生命周期管理、GRANT 原子性与超时语义、RETURN 原子幂等归还、配置变更隔离与账目边界）。既有 24 条需求不变。

## Impact

- **代码**：`lib/lease.lua`（新增）、`lib/redis.lua`（脚本表 + EVALSHA + 两新脚本）、`lib/algorithm.lua`（batch>1 接线）、`handler.lua`（扫描器 + 故障接线）、`schema.lua`（两个生命周期配置）；**`lib/store.lua` 整体废弃删除**（不保留两套 L2 实现）、compose 的 shared-dict 注入与相关 docs 清理；`redis/grant_lease.lua`、`redis/return_lease.lua`（新增独立脚本，双源同步）
- **测试**：resty 协议级确定性单测（注入时钟/借位场景由单测体系承接）、`bench/lease.sh`（新增 E2E）、`bench/matrix.sh` 扩展、既有回归（quota/dims/rules）
- **文档**：README、docs/design.md（§2/§4 重写为 Lease 架构）、docs/architecture.md、rule.md；报告 `reports/phase-4-performance-and-lease-return.md`
- **行为影响**：batch>1 路径整体重写（Redis 命令数锚点变化须在报告注明原因）；batch=1/多规则零变化
- **明确不做**（Deferred）：Redis Cluster、多规则本地库存、跨 Worker Lease 共享/接管、生产精确总账、SIGTERM 可靠归还、跨实例库存共享、Lease 过期补偿、GRANT 幂等、复杂分布式协调协议
