# Proposal

## Why

MVP 需求要求"覆盖 Request Path / Client ID / IP 等多维控制粒度"，Phase 2 已验证**单规则复合键**（`limit_by=[consumer,path]` = 一个桶），但真实业务还需要**多规则联合判定**：同一请求同时受"consumer 全局 100/时"与"consumer×path 10/时"两条独立配额约束，**全部桶有令牌才放行**；且任一桶不足时**所有桶都不消耗**（all-or-nothing，用户在人工验收后明确提出该原子性要求）。当前单桶语义无法表达，且这不是配置能绕过的——它需要多键原子判定与新的键结构，是一个独立的结构性能力。

## What Changes

- **α 强一致模式（用户已拍板）**：多规则模式**无本地库存**、无 batch 租约——每请求一次 Redis **多键原子 Lua**：全部桶够 1 ⇒ 各扣 1 放行；任一桶不足 ⇒ 全部不扣并返回不足规则列表（强一致：检查与扣减在 Redis 单线程脚本内完成，无本地回滚窗口）。该选择同时使"节点重启丢失租约"问题在多规则模式下不存在。
- **配置模型**：schema 新增 `rules` 数组（每条规则含 limit/window/burst/limit_by/header_name），单插件实例声明一组规则；`rules` 与 `limit_by` **互斥**（同现 → 下发即 400）；`rules` 非空时 `batch > 1` → 400（α 模式 batch 失义，fail fast）；规则数上限 8（脚本键数有界）。既有 `limit_by` 单规则形态行为**完全不变**。
- **组键结构**：`kong:rl:{<ns>:<组指纹>:r<i>:<dim>=<val>:…}` —— 组指纹 = 全部规则参数的 FNV-1a；**任一规则变更 ⇒ 整组新桶**（代价：改一条规则 = 整组配额重置，文档写明）；组内所有桶同 hash tag ⇒ 同 Redis Cluster slot（当初 hash tag 设计的前向兑现，Cluster 部署的前置条件）。
- **多规则响应语义**：放行时 `X-RateLimit-Remaining` = 各桶最小值（瓶颈规则）、`X-RateLimit-Reset` = 瓶颈规则的下一令牌时刻；429 响应体新增 `rule` 字段标明拒绝来源、`Retry-After` = 不足规则 wait 的最大值（封顶 = 各不足规则 window 的最大值）；判定日志含拒绝规则。
- **验证**：新增 `bench/rules.sh`——核心场景"R1 空 + R2 有 ⇒ 429 且两桶 tokens 均不变"（直接验收 all-or-nothing），以及全够放行、组键隔离、坏配置 400、单规则回归。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `rate-limiting`: 新增多规则联合判定的 ADDED 需求——多桶全或无原子性、组键结构与组指纹、强一致模式约束（互斥/上限/batch）、多规则响应语义。既有 19 条需求不变。

## Impact

- **代码**：`schema.lua`（rules 字段 + entity_checks 扩展）、`lib/redis.lua`（多键脚本 + parse_multi_grant_response）、`lib/algorithm.lua`（多规则决策分支）、`handler.lua`（多规则响应语义）；`lib/store.lua` 不动（rules 模式不使用本地库存）
- **测试**：新增 `bench/rules.sh`；既有 dims.sh/quota.sh 不受影响（单规则回归）
- **文档**：`README.md`（rules 配置与响应头）、`docs/design.md`（§2/§4 多规则原子性）、`docs/architecture.md`（决策流程图加多规则分支）、`rule.md`（键结构与 α 决策记录）
- **行为影响**：纯新增能力（`rules` 是新字段，旧配置行为不变）；Redis Cluster 部署从"前向兼容"变为"多规则硬前提"（组内同 slot）
- **明确不做**（留后续）：多规则的本地库存/batch 租约（β 增强，用户已定 α 先行）、节点重启的优雅归还 L2（Phase 4，仅影响单规则 batch>1）、租约对账 L3、跨插件实例的联合判定（结构性不可行，见 design D1）
