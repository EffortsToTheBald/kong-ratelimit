# Design

## Context

- 用户决策记录（2026-11-11 人工验收 phase2 后的讨论）：多规则联合判定采用 **α 强一致模式**——无本地库存、无 batch 租约，每请求一次 Redis 多键原子 Lua。理由链：本地 shared dict 无多键原子原语，"先检查 A、B 再扣"在本地是 TOCTOU 竞态（检查过≠扣得到，回滚机制一样少不了）；Redis 单线程 + 组内同 slot 的多键单脚本是唯一能提供"检查与扣减不可分割"的层。α 同时使"节点重启丢租约"（L2 归还问题）在多规则模式下不存在。
- **跨插件实例联合判定结构性不可行**：两个独立插件实例互相不可见，无法在一次原子操作内判定各自的桶——所以多规则必须收敛为**单插件实例声明一组规则**。这决定了配置模型（rules 数组）是本 change 最大的结构改动。
- 既有事实：单规则复合键（Phase 2 验证）、策略指纹（Phase 1）、entity_checks 前置校验（Phase 2）、fail-closed 默认（Phase 1）、组内同 slot 是当初 hash tag 设计的前向兼容承诺。
- `rules` 模式下每次请求恰好消耗每桶 1 个令牌（batch=1 语义），batch 字段失义——为防误导，schema 拒绝 rules+batch>1。

## Goals / Non-Goals

**Goals:**

- 多桶"全或无"原子判定（Redis 服务端单脚本），拒绝时返回不足规则。
- 配置模型：rules 数组 + 三类前置校验（与 limit_by 互斥、batch∈{0,1}、≤8 条）。
- 组键：同 hash tag + 组指纹（任一规则变更 ⇒ 整组新桶）。
- 多规则响应语义（瓶颈口径 + 429 标注拒绝规则）。
- 单规则形态零回归。

**Non-Goals:**

- 多规则的本地库存与 batch 租约（β 增强，后续 change；α 已定先行）。
- 节点重启的优雅归还 L2 / 租约对账 L3（Phase 4/5；仅影响单规则 batch>1 模式）。
- 跨插件实例联合判定（结构性不可行，文档明确声明）。
- 规则级独立 TTL 调优、动态增删规则不换桶（组指纹语义已排除）。

## Decisions

### D1. α：多规则 = 每请求一次多键原子 Lua，无本地库存

- `check()` 检测 `conf.rules` 非空 → 走多规则分支：构造全部桶键（组内同 tag）→ `redis.lua` 新函数 `grant_multi(conf, keys, want=1)` → 单脚本内"全检-全扣/全不扣"。
- 不触碰 `store`（无 take/fill），batch 字段不参与（schema 拒绝 >1）。
- 后果：多规则模式每请求 1 RTT（无快路径）——强一致的直接代价，用户已拍板；重启丢租约问题在该模式下不存在。
- 备选 β（本地多池租约 + 扣-验-滚）被否为 v1：崩溃窗口泄漏 ≤N−1 令牌虽是少发方向，但"先检查后扣"的需求本意是强一致，β 留作后续增强。

### D2. 配置模型与三类前置校验

```lua
{ rules = {
    type = "array", len_max = 8,
    elements = { type = "record", fields = {
      { limit = integer, required },
      { window = number, default 60 },
      { burst = integer, default 0 },
      { limit_by = array（同 DIMENSIONS，默认 {"consumer"}）},
      { header_name = string },
    } },
} },
```

- entity_checks 扩展三条（延续 Phase 2 的 conditional/contains 手法，必要时 custom_entity_check）：
  1. `rules` 非空 ⇒ `config.limit_by` 不得显式设置——**实现注意**：`limit_by` 有默认值 `["ip"]`，"显式设置"无法从投影区分。可行做法：rules 非空时**忽略并 warn**？否——歧义必须硬拒。落地方案：`limit_by` 默认值改为 nil（required 化会让旧配置破坏——不行）。**最终方案**：rules 非空 + `limit_by ≠ ["ip"]`（默认值）→ 400 拒绝（custom_entity_check 比较）；等于默认值时视为未设置（文档注明：rules 模式下 limit_by 无效）。实施首日实测该比较在 entity_check 中的行为。
  2. `rules` 非空 ⇒ `config.batch` ∈ {0,1}（batch>1 → 400）。
  3. `#rules ≤ 8`（len_max 直接表达）。
- 运行时兜底（build_key/check 入口）同步校验，双保险。

### D3. 组键结构

```
kong:rl:{<ns>:<组指纹>:r<i>:<dim>=<val>:…}
```

- 组指纹 = FNV-1a(每条规则的 limit/window/解析后 burst/limit_by/header_name 按序拼接)——任一规则变更 ⇒ 组指纹变 ⇒ 整组新桶（旧桶 TTL 淘汰，代价写进文档）。
- `r<i>` 为规则序号段（i = 规则在 rules 数组中的下标）；维度值段与单规则形态一致。
- 组内全部桶同 hash tag ⇒ 同 slot：多键 EVAL 的 Cluster 前提，单实例 Redis 无感。
- 桶内 Hash 字段沿用 `tokens`/`ts`（与单规则桶同构，脚本复用 refill 公式）。

### D4. 多键原子脚本（grant_multi）

```
KEYS: r1 桶键, r2 桶键, … rN 桶键
ARGV: [n, r1_rate, r1_burst, r1_ttl, r2_rate, …]
逻辑（单脚本，Redis 串行）：
  1. 逐桶 HMGET tokens/ts → refill（TIME 单调、burst 封顶，与单桶脚本同公式）
  2. 全检：所有桶 refill 后 tokens ≥ 1？
  3. 全部够 → 各桶 HSET(tokens-1, ts=now) + PEXPIRE(各桶 ttl_i) → 返回 {ok=1, 各桶 tokens/wait}
     任一不足 → 不写任何桶 → 返回 {ok=0, 不足规则序号列表, 各不足桶 wait}
```

- wait 公式沿用统一口径 `max(0,(1−tokens)/rate)`（仅对不足桶计算）。
- 返回值仍为扁平数组（Redis Lua 返回约定），`parse_multi_grant_response(keys_count, want)` 纯函数防御校验（延续 Phase 2 D3 手法：结构/数值/范围），畸形 → close + nil,err → 故障分支。
- 单桶脚本（单规则路径）保留不动；独立脚本文件 `redis/multi_bucket.lua` 新增，与内嵌双源同步（延续 Phase 1 的双源约定与 diff 校验）。

### D5. 多规则响应语义

- 放行：`Remaining = min(各桶剩余)`（瓶颈规则）、`Reset = 瓶颈桶的 now+wait`（wait=0 即 now）；日志含全部规则的 key。
- 429：响应体 `rule` = 不足规则的人类可读标识（如 `rules[2]:consumer+path`）；`Retry-After = max(不足桶 wait)` 封顶 `max(不足桶 window)`；Reset 与 Retry-After 同口径（延续 Phase 2 口径）；判定日志含拒绝规则。
- 响应头口径在 README/design 标注"瓶颈规则视角"。

### D6. 兼容与回归边界

- 未配 `rules`（仅 limit_by）→ 现有单规则路径一行不动（batch 租赁、本地库存、快慢路径、Phase 2 响应头语义全部保留）。
- dims.sh / quota.sh / xff.sh 全部走单规则形态 → 自动成为回归防线。
- 新验证 `bench/rules.sh` 独立成脚本（不并进 dims.sh，关注点分离）：核心场景用 redis-cli HSET 预置桶状态直接构造"一空一有"，验收"429 且双桶 tokens 不变"（用户提出的原始验收标准）。

## Risks / Trade-offs

- [多键脚本的复杂度与正确性] → 脚本逻辑与单桶脚本同构（refill 公式复用），差异仅在"多桶全检全扣"；resty 纯函数单测 + redis-cli 独立脚本裸跑（token_bucket.lua 的 Day-1 手法）先行验证，再接插件。
- [limit_by 默认值与"显式设置"的区分不精确] → 采用"rules 非空 + limit_by ≠ 默认值 → 400"的近似语义，文档写明 rules 模式下 limit_by 无效；实施首日实测该比较，不精确则退化为"rules 模式下忽略 limit_by + init warn"并修订 spec 措辞（风险链已标注）。
- [组指纹重置语义] → 改任一规则 = 整组配额重置，写入 README/design；逃生门仍是 namespace。
- [429 `rule` 字段暴露内部结构] → 字段为人可读规则描述而非内部序号裸值；对网关调用方是诊断信息，利大于弊。
- [Cluster 前提] → 单实例 Redis 下无感；多规则在 Cluster 部署时必须保证组内同 tag（本设计已保证），文档标注"多规则的 Cluster 硬前提"。
- [每请求 1 RTT 的性能代价] → α 已拍板；Phase 4 性能矩阵把多规则模式作为独立测点量化。

## Migration Plan

1. 基线 commit；实施首日实测 D2 的 entity_check 近似语义（不精确即走退化方案并修订 spec 措辞）。
2. schema（rules + 三校验）→ resty 验证 400/201 矩阵。
3. `redis/multi_bucket.lua` + 内嵌多键脚本 → redis-cli 裸跑验证全检全扣 → 插件接入 + `parse_multi_grant_response` 单测。
4. algorithm/handler 多规则分支 + 响应语义。
5. `bench/rules.sh` 全绿；dims.sh/quota.sh 回归全绿（单规则零回归）。
6. 文档同步（README/design/architecture/rule.md）→ `reports/phase-3-multi-rule.md`（§13 格式）。
7. 回滚：组级 commit revert；新键结构无持久化迁移问题（旧桶 TTL 淘汰）。

## Open Questions

（无阻塞项。D2 中 limit_by"显式设置"的判定精度为实施首日事实核查，退化路径已标注。）
