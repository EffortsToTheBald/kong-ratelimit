# Phase 6 请求路径集成 · 最终验收报告（V1）

- **日期**：2026-11-13
- **基线**：`a3214b76b70164c51be52458e34fb72f6cc720ed`（Phase 6.5 最终提交）
- **性质**：最终集成验收——静态代码审计 + 测试证据汇总 + 交付材料；生产代码零修改

---

## 1. 项目背景与本次改造目标

`rate-limit-advanced` 是 Kong 3.6 DB-less 插件，提供分布式令牌桶限流（Redis Lua 原子授权）。改造前（Phase 1–3 Legacy）batch>1 依赖 `ngx.shared.DICT` 聚合本地库存，存在跨 Worker 语义模糊、慢路径 Redis 压力与 shared-dict 依赖问题。

本次改造（`phase4-performance-and-lease-return` 提案，Phase 4–6）：引入 **Worker Local Lease Manager**——单规则 batch>1 路径改为"Redis GRANT_LEASE 批量预授权 + Worker 本地 TAKE 消费"，每请求 Redis 压力降为 O(1/batch)，保持全局配额不超发，并采用明确的 Fail-close 故障策略；batch>1 已确认的本地库存允许在 Redis 故障期间继续消费，而新 GRANT 失败时进入故障处理。

## 2. V1 功能范围与非目标

**已实现且已验证（本报告 §10–§11）**：
- batch=1：每请求 Redis Lua 逐请求授权（严格全局一致，语义与改造前零变化）
- 单规则 batch>1：GRANT_LEASE 批量预授权 + Worker 本地 TAKE
- 多规则：GRANT_MULTI 原子多键扣减（全或无），不使用 Lease
- Redis 故障 Fail-close / fault_tolerant 双路径；超时不确定结果处理
- 策略指纹配置隔离；EVALSHA 懒加载 + NOSCRIPT 自愈

**V1 非目标（Deferred，未实现）**：自动 RETURN 归还、idle scanner、max_lifetime、Worker 接管、库存补偿、精确实时 lost 审计、Redis Cluster、实时性能指标。详见 §13–§14。

## 3. 整体架构

```
请求 → handler.lua(access)
      ├─ algorithm.build_key(conf) ── 桶键 = 前缀:{ns:p=<策略指纹>:<维度>=值...}（D7 一体格式）
      └─ algorithm.check(conf, key)
          ├─ 多规则          → check_multi → Redis GRANT_MULTI（原子多键，全或无）
          ├─ batch=1         → Redis token_bucket Lua（每请求 EVAL，严格全局一致）
          └─ 单规则 batch>1  → check_lease
              ├─ lease.take(pool_key)      [Worker 本地，非 yield 原子片段，零 IO]
              ├─ NEED_GRANT → redis GRANT_LEASE（EVALSHA，桶扣减+建记录原子）
              │     ├─ granted≥1 → lease.grant 登记（同 worker VM 内追加）→ 再 TAKE 恰消费 1
              │     ├─ granted=0 → 429（Retry-After 透传）
              │     ├─ explicit_error → nil,err（Fail-close；Lua 执行错误不保证回滚此前写入，可能造成库存损失，但不会将未确认授权的库存登记到本地）
              │     └─ uncertain（超时/断连/畸形）→ nil,err（不重试、不登记、允许损失）
              └─ 放行/429 → handler 设置 X-RateLimit-* 头（remaining=本地池余量）
```

- Lua VM 按 Worker 隔离 ⇒ `_pools`/`_counters` 天然 Worker 私有（结构性隔离，非约定）
- Redis 侧职责：全局桶状态、GRANT 原子扣减与 Lease 记录（TTL 1h）；**不感知本地消费**
- Worker 侧职责：库存消费（TAKE）、Lease 生命周期（ACTIVE→CLOSED 单向）、诊断计数

## 4. 三条请求路径（代码审计结论）

| 路径 | 实现 | 审计位置 | 结论 |
|---|---|---|---|
| batch=1 | 每请求 `redis_mod.grant`（EVAL token_bucket） | algorithm.lua:452–490 | ✓ 与改造前语义零变化；Phase 6.4 实证 EVALSHA 恰=请求数（450）、Lease 记录=0 |
| 单规则 batch>1 | `check_lease`：本地 TAKE→GRANT_LEASE→登记→再 TAKE 消费 1 | algorithm.lua:341–421 | ✓ granted≥1 ⇒ TAKE 必成功，防御分支按故障处理（不放行未授权库存） |
| 多规则 | `check_multi` → GRANT_MULTI（全或无） | algorithm.lua:434–436、redis.lua GRANT_MULTI | ✓ 不进入 Lease 路径；"一空一有 ⇒ 429 且双桶不变"实测 |

## 5. Redis Lua 与 Worker Local Lease 职责划分

- **Redis Lua（Phase 2–3 冻结协议，双源 diff 校验）**：token_bucket / GRANT_MULTI / GRANT_LEASE / RETURN_LEASE（已实现、V1 不接线）。GRANT_LEASE 单脚本原子完成参数校验→refill→部分授予判定→扣桶→建 Lease 记录→TTL；tokens<1 ⇒ granted=0 不建记录
- **Worker Local Lease（Phase 4，lease.lua）**：`_pools[pool_key]` = `{leases, active}`；TAKE 在**不含 yield 点的同步片段**内完成检查+递减（协程调度不会插入 ⇒ 原子性完整证明，无补偿路径）；不变量 `remaining + consumed = granted`（lease-unit 25 断言守护）
- **EVALSHA 管理（Phase 2）**：懒加载（init_worker 零 IO）；仅明确 NOSCRIPT 触发 LOAD+重试恰一次；超时/断连绝不当作 NOSCRIPT（防止重复执行已成功扣减）

## 6. Lease 生命周期与库存账目

- 生命周期（V1 冻结）：**ACTIVE → CLOSED 单向**。`remaining=0` ⇒ 置 CLOSED + 从 active 摘除（同片段内完成），保留在 `leases` 表仅作诊断；不可复活、不重入消费；无 CLOSING 归还态、无 Redis RETURN 调用
- 账目：正常运行 `granted = consumed + outstanding`；Worker 崩溃后 `granted = consumed + lost`
- **实测数据（Phase 6.5 worker-crash-e2e，Worker PID=1322，lease `8b8a3f9f9422:1:370:294bea`）**：
  - 崩溃前：`10 = 4（consumed）+ 6（outstanding，remaining 头序列 9,8,7,6）`
  - 崩溃后：`10 = 4 + lost 6`；其余 Worker `90 = 90 + 0`；全局 `Σgranted=100 = HTTP 放行 94 + lost 6`（94≠100 ⇒ 无接管/补偿/RETURN）
- **观测口径声明**：consumed 是 Worker 本地行为，Redis 记录不可直接观测；证据链 = Redis granted 字段（记录）+ HTTP 200 计数（每成功请求恰 1 次 TAKE）+ `X-RateLimit-Remaining` 头（=本地池余量，algorithm.lua:423–424）三源交叉。CLOSED 为本地语义，Redis 侧记录保持 OPEN 至 TTL 1h

## 7. 配置指纹与 Pool 隔离

- 指纹输入（algorithm.lua:35–53）：`limit / window / burst（归一化 ≤0⇒limit）/ limit_by 顺序 / header_name（仅含 header 维度时参与）`；**batch 不参与**（运输参数，调 batch 不清空桶）
- `pool_key = build_key 输出 = Redis 桶键`（D7 一体格式，非第二套 Key 体系）⇒ 配置变化经指纹变化自然隔离旧库存
- 实测：五维度隔离矩阵 + 真栈配置变更（limit 100→200）后新配置首请求 remaining=9（排除复用旧库存 8）、新记录指纹段变化（`p=50780f62`→`p=95b99e16`）、旧记录/旧桶原样（PHASE6_3_REPORT）

## 8. Redis 故障与不确定结果处理

| 场景 | 语义 | 实测证据 |
|---|---|---|
| 连接拒绝 | ft=false ⇒ 503 Fail-close；ft=true ⇒ 降级（X-RateLimit-Status: degraded）；**不伪装 429** | handler-fault-e2e 26 断言 |
| 执行超时 | batch=1/batch>1 均进既有故障分支；batch>1 不确定结果**不重试、不登记本地库存、不当作 granted=0** | 同上 + 场景 B |
| 不确定结果（已执行、响应丢失） | 503；Redis 侧记录恰 1（无重试）；同 Worker 后续请求 rem=9 + 记录 +1（未登记幻影库存） | lease-timeout-uncertain-e2e 场景 B（fd5 keepalive + inode→fd→PID 三次核对归属，22 断言） |
| 确定性未执行 | 503；记录=0（CLIENT KILL 丢弃排队命令实证） | 同上场景 A |
| 故障期间已有库存 | 确认库存仍可本地 TAKE（PAUSE 期间 req2-10 全 200）；耗尽后新 GRANT 进故障分支 | P1 场景 |
| 恢复后 | 独立请求正常申请；无重复授权（记录增量恰 +1） | fault-recovery-e2e 12 断言 |

## 9. Worker 崩溃后的库存损失语义（V1 冻结）

崩溃 Worker 的 outstanding 在崩溃后归类 **lost**：不归还、不补偿、不接管、不重新授权。全局账目因此**保守偏损**（绝不超发）。V1 不提供实时 lost 指标（Phase 5 Deferred）；审计手段 = GRANT 记录 + 消费计数 + 崩溃事件 + 后续授权行为推导（§6 实测：6/100 永久损失）。

## 10. Phase 0–6.5 实施过程与 Commit 对照

| 阶段 | 内容 | 关键 Commit | 交付报告 |
|---|---|---|---|
| Phase 0 | 骨架回滚基线 + P0 审查 | `0318d2b` | docs/PHASE0_REVIEW.md、review-phase-0.md |
| Phase 1 | 正确性基线（指纹 Key/时间戳单调/Fail-close/压测收敛/IP 维度回归） | `cb1a2f5`…`f499afe`（组1–8）、归档 `07d392c` | test/phase1-manual.md、docs/results.md |
| Phase 2 | 维度与语义（响应头/校验防御/多维验证）+ 归档 | `32572d5`…`e156e86`、`cee858c` | docs/PHASE2_REVIEW.md、test/phase2-manual.md |
| Phase 2(EVALSHA) | 脚本管理（懒加载/NOSCRIPT 恰一次自愈） | `e4dd6c8`、`b700417`、`3423457` | Phase 2 review（PASS 无 P0/P1） |
| Phase 3(提案+多规则) | rules 模型/GRANT_MULTI 双源/决策语义/回归 | `e074034`…`f5656bb`、归档 `3f78b21` | docs/PHASE3_GROUP1_REPORT.md |
| Phase 3(Lua 协议) | GRANT_LEASE/RETURN_LEASE 脚本 + 审查修复 | `d53f3f0`、`d30592b`、`e1155b5` | lease-redis-matrix.sh 50 断言 |
| 冻结修订 | V1 scope 调整（Phase 5 Deferred、状态机简化） | `aa3294a`…`089e588`（5 commits） | V1_SCOPE_ADJUSTMENT.md |
| Phase 4 | Worker Local Lease Manager + 性能基线报告 | `8b04976`、`17cfe37`、`d2a6107` | docs/PHASE4_WORKER_LEASE_REPORT.md |
| Phase 6.1 | algorithm 接线（check_lease/LEASE_TTL_MS） | `a3755aa` | —（tests 内嵌证据） |
| Phase 6.2 | handler 清理（去 store/shared-dict）+ 测试修正 | `2d4262a`、`55a8131` | — |
| Phase 6.3 | 配置隔离测试（5 维度 + 真栈变更）+ 审查修正 | `146fdde`、`cbaaf12` | docs/reports/PHASE6_3_REPORT.md |
| Phase 6.4 | 全量回归 + 故障双路径 + EVALSHA 自愈 + 证据修正 | `f73c0a8`、`63b9d45` | docs/reports/PHASE6_4_REPORT.md |
| Phase 6.5 | 并发/耗尽/崩溃/超时不确定 + 同 Worker 归属修正 | `4622b94`、`a3214b7` | docs/reports/PHASE6_5_REPORT.md |

## 11. 完整测试矩阵

| 阶段 | 测试内容 | 执行状态 | 结果 | 证据位置 |
|---|---|---|---|---|
| Phase 0 | 代码审查（P0 基线） | 历史已执行 | 审查结论落盘 | docs/PHASE0_REVIEW.md |
| Phase 1 | 手动验收 11 case + rule.md A–D + 正确性回归 | 历史已执行 | 全绿 | test/phase1-manual.md、`f5656bb` |
| Phase 1 | 性能基线（Legacy EVAL + Shared Inventory） | 历史已执行 | 见 §12 | docs/results.md、bench/raw/phase1/ |
| Phase 2 | 手动 10 case + dims.sh 8 场景 | 历史已执行 | 8/8 | test/phase2-manual.md、docs/PHASE2_REVIEW.md |
| Phase 2 EVALSHA | evalsha-unit（NOSCRIPT 恰一次/超时不触发 LOAD） | 历史已执行 + 6.4 重跑 | 8/8 | test/evalsha-unit.sh |
| Phase 3 | rules.sh 14 场景（含一空一有⇒429 双桶不变） | 历史已执行 + 6.4 重跑 | 14/14 | bench/rules.sh |
| Phase 3 Lua | lease-redis-matrix.sh 协议矩阵 | 历史已执行 | 50 断言全绿 | test/lease-redis-matrix.sh、`d30592b`/`e1155b5` |
| Phase 4 | lease-unit 25 / lease-grant-smoke / lease-isolation | 历史已执行 | 全绿 | test/lease-unit.sh、docs/PHASE4_WORKER_LEASE_REPORT.md |
| Phase 6.1 | algorithm-lease-unit 17 + algorithm-lease-e2e 15 | 历史（6.1 组）已执行 | 全绿 | test/algorithm-lease-unit.sh、test/algorithm-lease-e2e.sh |
| Phase 6.2 | handler-fault-e2e 26（故障双路径 + 双 Worker 库存） | 历史已执行 + 6.4/6.5 间接回归 | 26/26 | test/handler-fault-e2e.sh |
| Phase 6.3 | config-isolation 15 + 真栈 E2E 14 | 历史已执行（审查修正后） | 全绿 | docs/reports/PHASE6_3_REPORT.md |
| Phase 6.4 | quota b1（EVALSHA 恰 450/lease 0）+ b20（账目 355=350+5+95）+ dims 8 + rules 14 + handler 26 + fault-recovery 12 + script-cache-selfheal 15 + evalsha-unit 8 | 历史已执行（63b9d45 v2 口径） | 全绿（FAIL 0） | docs/reports/PHASE6_4_REPORT.md |
| Phase 6.5 | concurrent 17 + exhaustion 11 + crash 16 + timeout **22**（v2 同 Worker 归属） | **最终提交 a3214b7 实际执行，连续 3 轮全绿** | 66/0/0 | docs/reports/PHASE6_5_REPORT.md |
| Phase 7.2 | batch=1 与 batch=10 同口径性能实测（Lease 实现） | **NOT RUN / Deferred** | — | Spec `batch=1 与 batch=10 同口径实测` 场景 |
| Phase 5 | 自动 RETURN/idle/max_lifetime/接管 | **Deferred（未实现）** | — | V1_SCOPE_ADJUSTMENT.md |

**静态审查证据（本阶段新增，任务 1）**：对 handler.lua（106 行全读）、algorithm.lua（check/check_lease/fingerprint/build_key）、lease.lua（take/grant/classify/CLOSED）、redis.lua（evalsha/grant_lease/grant_multi/connect）逐条对照冻结 Spec/Design 的 11 项审计全部通过（结论见 §15）。区别于测试证据：上述为代码级核对，不含新执行。

## 12. 性能基线与当前性能证据边界

**来源：docs/results.md（Phase 1 Legacy 性能基线——EVAL + Shared Inventory，k6 v0.54 三轮 matrix.sh，20 核共享宿主机，数据为真实运行）**。摘要（RPS=1000 档）：

| 模式 | p99 | Redis QPS | EVAL |
|---|---:|---:|---:|
| M0 基线（无限流） | 1.8ms | ~0 | 0 |
| batch=1 | 3.1ms | 4865 | 20001 |
| batch=10 | 2.2ms | 434 | 2001 |
| batch=100 | 2.8ms | 42 | 171 |
| 多规则 | 3.2ms | 7583 | 20001 |

**边界（必须明确）**：
1. 以上全部来自 **Legacy 实现（EVAL + shared-dict 聚合库存）**，**不能代表当前 Lease Manager 实现**，不得冒充新实现实测数据。
2. 当前版本（Lease 路径）的性能同口径实测属 Phase 7.2（Spec 场景 `batch=1 与 batch=10 同口径实测`），**NOT RUN**。
3. 当前可引用的间接证据（非性能口径）：Phase 6.4 `CONFIG RESETSTAT` + commandstats——batch=1 下 EVALSHA 恰=请求数（450/450）；batch=20 下 450 请求 355 次 GRANT 尝试、95 次纯本地 TAKE 零 Redis。EVALSHA 相比 EVAL 有脚本体积字节传输收益（如实陈述），**无延迟显著提升的实测证据，不做此声称**。

## 13. 已知限制与 Deferred 功能

**已实现且已验证**：§2 前半 + §4–§9 全部行为（证据 §11）。
**已实现但验证范围有限**：CLOSED 本地语义（Redis 不可见，经 remaining 序列间接实证）；lost 审计（推导式，无实时指标）；burst=nil≡0 归一化等价（单测覆盖，属设计语义）。
**尚未实现（Deferred，不得宣称具备）**：自动 RETURN 归还（RETURN_LEASE Lua 已实现但 V1 不接线）、idle scanner、max_lifetime、Worker 接管/库存补偿、Redis Cluster 脚本缓存按节点、监控指标接口、Phase 7 性能同口径实测、Phase 8 store.lua 清理。

## 14. 生产化差距分析（V1 → 生产级）

| # | 差距 | 影响 | V1 当前处理 | 未来方向（未实现） |
|---|---|---|---|---|
| 1 | Worker 崩溃库存损失 | batch 越大损失越大（实测 6/100）；可用性换一致性 | 保守偏损（不超发）+ TTL 1h 侧兜底 | Phase 5 RETURN_LEASE 接线 + 精确 lost 指标 |
| 2 | batch>1 预授权时序 | 放行呈 batch 粒度阶跃；突发期单 Worker 可一次预授权 batch 个 | 账目核验口径明示（denied-GRANT 语义） | 更小 batch/auto 策略文档化；按流量画像调参 |
| 3 | Redis Cluster 多键 Lua | GRANT_MULTI/多键脚本要求同 slot；单实例假设 | 单实例部署（compose standalone） | Cluster 化需 hash-tag 或按 ns 拆分（Deferred） |
| 4 | Redis 高可用/故障切换 | 主从切换期间全部 GRANT 失败 ⇒ Fail-close 拒绝 | 既有故障语义 + 本地库存缓冲（确认库存可用） | Sentinel/Cluster 客户端、拓扑感知重试策略 |
| 5 | Lease TTL 与本地生命周期 | Redis 记录 TTL 1h（LEASE_TTL_MS 硬编码），本地 CLOSED 记录永不清理 | 留存诊断表（V1 冻结） | Phase 5：idle/max_lifetime 归还时同步清理 |
| 6 | 限流策略动态更新 | 旧 Pool 库存自然消亡（不返还）；本地诊断表只增 | 指纹隔离实证（新配置不复用旧库存） | 池回收策略（Phase 5 一并） |
| 7 | 可观测性 | 无 Prometheus 指标/Tracing；RL-DEBUG notice 日志为热路径噪声（P3） | 结构化错误日志 + Redis 记录 + remaining 头 | 指标导出（granted/consumed/lost/closed 计数已有 _counters 基础） |
| 8 | 高并发本地状态 | `_pools` 按 (ns,指纹,维度值) 增长；多租户大维度基数下内存增长 | TTL 1h 由 Redis 兜底，本地仅诊断 | 维度基数上限/池淘汰（Deferred） |
| 9 | 长稳/内存稳定性 | 未做 >24h 长稳与内存曲线 | 短时压测 + 单测不变量守护 | 长稳测试套件（Phase 7+） |
| 10 | 性能压测缺口 | 当前实现性能无同口径实测（§12） | Legacy 基线 + 账目级 Redis 命令数证据 | Phase 7.2 同口径（batch=1 vs batch=10，Worker 1/多 × 速率三档） |

**代码级 P2/P3（不扩大本阶段范围，列入后续）**：
- P3：algorithm.lua:483 `store.fill` 为 batch=1 路径内不可达死代码（batch>1 已改走 check_lease）；`store.lua` 本体待 Phase 8 冻结删除（design.md:258，测试全绿前提）
- P3：docker-compose `KONG_NGINX_HTTP_LUA_SHARED_DICT: kong_rl 32m` 注入已不被插件使用（handler 无 shared-dict 依赖），残留无害；建议 Phase 8 一并删除并同步 docs
- P3：`[RL-DEBUG]` notice 级日志在热路径（local_hit/lease_grant/lease_take_after_grant），生产应降级为 debug 或配置开关
- P3：`LEASE_TTL_MS=3600000` 硬编码（注释已注明 Phase 5 交还配置管理）

**P0/P1：无**（详见 §15）。

## 15. 最终代码审计结论（任务 1，11 项逐条）

| # | 审计项 | 结论 | 依据 |
|---|---|---|---|
| 1 | Phase 6.1–6.5 实现符合冻结 Spec/Design | ✓ | 逐文件对照（§4–§9 位置引用） |
| 2 | batch=1 保持原逐请求 Redis 路径 | ✓ | algorithm.lua:452；实测 EVALSHA=450/450、lease 0 |
| 3 | batch>1 正确使用 Lease Manager | ✓ | algorithm.lua:453–455 → check_lease |
| 4 | 多规则继续 GRANT_MULTI、不进 Lease | ✓ | algorithm.lua:434–436；rules.sh 全绿 |
| 5 | GRANT 成功登记 + 当前请求恰消费 1 | ✓ | algorithm.lua:400–421（TAKE 必成功 + 防御分支按故障处理） |
| 6 | granted=0 正确 429 + Retry-After | ✓ | algorithm.lua:387–398/465–476；handler D2 封顶 |
| 7 | 异常/不确定进故障处理 | ✓ | classify 四分类（explicit_error/uncertain ⇒ nil,err）；handler 24–38 |
| 8 | Worker 本地库存严格隔离 | ✓ | lease.lua `_pools` per-VM；结构性不可见；实测 6 Worker (host,worker) 全覆盖 |
| 9 | 配置指纹隔离旧库存 | ✓ | fingerprint_input（batch 不入）；6.3 全绿 |
| 10 | Handler 无 shared-dict 降级告警/错误依赖 | ✓ | handler.lua 无 store/shared 引用；VERSION 0.2.0；init_worker V1 notice |
| 11 | 错误处理/泄漏/状态一致性/并发安全 | ✓（P3 见 §14） | TAKE 非 yield 原子；set_keepalive(10s,100)；不变量单测守护；nil 先判（rule.md §9.1 问题A 已修） |

**发现的问题**：无 P0/P1。P2/P3 全部列入 §14 后续改进，不阻塞交付。

## 16. 生产部署、监控与运维注意事项

- **部署**：DB-less 3 节点 × 2 Worker 形态已验证；schema 支持单规则（limit/window/batch/burst/limit_by/header_name）与多规则（rules 数组）；`fault_tolerant=false`（默认）= Fail-close
- **调参**：batch 是可用性/损失粒度的权衡（越大 Redis 压力越小、崩溃损失越大）；schema 允许显式 batch 不 clamp（大 batch 需自行评估损失敞口）；burst≤0 归一化为 limit
- **监控建议**（基于现有可观测点）：Redis lease 记录数/状态（SCAN kong:rl:lease:*）、桶 tokens（HGET）、handler 错误日志（`limiter unavailable` = 故障分支；`lease grant failed (uncertain)` = 不确定结果）、X-RateLimit-Remaining 头采样
- **故障演练**：本仓库测试脚本可直接复用为演练（stop redis / CLIENT PAUSE / CLIENT KILL / SIGSTOP·CONT / kill -9 worker）
- **升级注意**：配置变更即指纹变更 ⇒ 旧库存自然消亡（不迁移）；Redis 脚本缓存实例级（重启 Redis 后首次请求自愈，NOSCRIPT 恰一次）

## 17. 最终验收结论

1. **Phase 6.6 完成**：静态审计（11 项全过、无 P0/P1）+ 测试证据汇总 + 性能边界声明 + 本报告交付。
2. **Phase 0–6 可整体标记完成**：三条请求路径、故障语义、配置隔离、并发安全、崩溃损失、脚本自愈均有测试实证；冻结范围内 V1 范围裁决（Phase 5 Deferred）已如实标注。
3. **未解决 P0/P1：无**。
4. **面试/技术展示条件：具备**——架构决策链（为什么 Worker 本地 Lease、为什么 pool_key=桶键、为什么不确定结果不重试）、冻结设计文档（openspec artifacts + 5 份阶段报告）、66 项 6.5 断言与全阶段测试矩阵、真实账目数据（10=4+6 / 100=94+6）均可支撑讲解；讲解时须区分"已验证行为"与"Deferred 能力"（§13）。
5. **Phase 7 起点**：按冻结 Spec 的 `batch=1 与 batch=10 同口径实测` 场景执行性能验证（k6 同口径，覆盖 Worker 1/多 × 速率低/中/高），产出 `test: add phase4 lease performance report`；随后按 design.md:258 执行 Phase 8 清理（store.lua/死代码/shared-dict 注入/RL-DEBUG 日志降级）。

---

*本报告基于 HEAD `a3214b7` 实际代码与各阶段报告的真实执行记录生成；生产代码零修改（git diff 仅含本报告与 tasks.md 状态）。*
