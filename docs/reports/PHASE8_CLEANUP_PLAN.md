# Phase 8.1 报告：最终清理审计与实施计划

- **日期**：2026-11-14
- **基线 HEAD**：`bc46c8c0fcaf8476f3544ffec0aa22a307fbe60c`（工作区干净，仅 `1113.json` 未跟踪会话导出）
- **性质**：只审计与制定计划；**本阶段零代码/文档/配置修改**

---

## 1. 当前项目状态（能力与证据对照）

| 能力 | 状态 | 证据 |
|---|---|---|
| batch=1 逐请求 Redis 授权 | 已实现且有证据 | EVALSHA==请求数（Phase 6.4 恰 450、Phase 7 干净轮 20001=20001）、Lease 记录 0 |
| 单规则 batch>1 Lease 预授权 | 已实现且有证据 | Phase 6.5 四脚本 66 断言（含同 Worker 归属 inode→fd→PID 三次核对）；Phase 7 授权命令 20001→2002（约 9.99:1） |
| 多规则 GRANT_MULTI 全或无 | 已实现且有证据 | rules.sh 14/14（一空一有⇒429 双桶不变）、Phase 7 三方账目相等 |
| 故障双路径/超时不确定/恢复 | 已实现且有证据 | handler-fault-e2e 26、fault-recovery 12、场景 A/B 三态区分 |
| 配置指纹隔离 | 已实现且有证据 | config-isolation 15+14 |
| EVALSHA 懒加载+NOSCRIPT 恰一次自愈 | 已实现且有证据 | evalsha-unit 8 + script-cache-selfheal 15 + Phase 7 SCRIPT_LOAD=0（87 组） |
| 并发安全/崩溃损失账目 | 已实现且有证据 | lease-unit 25、worker-crash 16（10=4+6，无接管） |
| 性能（同口径） | 已实现且有证据 | Phase 7 报告 + bench/raw/phase7/（95 文件） |
| 自动 RETURN/idle scanner/max_lifetime/Worker 接管/补偿 | **Deferred，未实现** | V1_SCOPE_ADJUSTMENT.md（Lua 协议已备 RETURN_LEASE 但不接线） |
| Redis Cluster/HA、指标导出、长稳 | **未实现/未验证** | Phase 6.6 §14 生产化差距分析 |

## 2. 目录结构审计

```
kong/plugins/rate-limit-advanced/
├── handler.lua      (106 行) access 阶段决策出口：build_key→check→放行/429/503；无 store/shared 引用 ✓
├── schema.lua       配置校验（rules/batch/redis 等；无 shared-dict 相关字段 ✓）
└── lib/
    ├── algorithm.lua (494 行) 决策核心：build_key/指纹/check/check_lease/check_multi/rate_and_burst
    ├── lease.lua     (351 行) Worker 私有 Lease Manager：take/grant/classify_grant/_pools/_counters
    ├── redis.lua     (749 行) Redis 客户端：connect/set_keepalive/evalsha 自愈/token_bucket/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE(未接线)
    └── store.lua     (87 行) 【废弃候选】shared-dict 聚合库存（Legacy batch>1 唯一实现）
bench/{common,matrix,quota,dims,rules,xff}.sh + k6/latency.js    性能框架（Phase 7 已扩展 leaseGrant 列）
test/*.sh|*.lua                                                   Phase 0–6.5 全套回归 + E2E
docs/ + docs/reports/                                             Phase 0–7 报告 + 集成报告
openspec/changes/phase4-performance-and-lease-return/             冻结 Spec/Design/tasks
```

依赖关系：handler→algorithm→{lease,redis,store}；redis 独立；lease 独立（redis 客户端经回调注入）。**store 依赖单向且唯一**（algorithm.lua:10）。

## 3. 遗留代码清单（逐项引用分析，非文件名推断）

### 3.1 `lib/store.lua`（87 行）

- **代码位置**：整文件（DICT_NAME="kong_rl"、take/fill/dict_mode/降级逻辑）
- **当前引用**：全仓库唯一 require = algorithm.lua:10；唯一调用 = algorithm.lua:483 `store.fill(key, granted.granted - 1, ttl_s)`
- **是否在有效调用链**：**否**——483 行位于 `if batch > 1 and granted.granted > 1` 分支内，而 `check()` 在 batch>1 时已于 algorithm.lua:453–455 转入 `check_lease` 并 return ⇒ 该分支不可达（死代码）
- **其他引用**：bench/quota.sh:94（仅注释文案）；README.md:26/205、docs/architecture.md:13/65/72（文档描述已过时）
- **建议**：**删除** store.lua 整文件 + algorithm.lua:10 require + :480–484 死代码块 + compose `KONG_NGINX_HTTP_LUA_SHARED_DICT: "kong_rl 32m"` 注入 + 同步 README/architecture
- **删除影响**：无运行时影响（Phase 7 实测 EVAL=0 证明当前路径零 EVAL/shared 行为）；docker-compose 重启后 shared dict 不再分配 32m
- **验证方式**：全回归（lease-unit 25 / algorithm-lease 17+15 / config-isolation 15+14 / handler-fault 26 / quota b1+b20 / dims 8 / rules 14 / 6.5 四脚本）+ Phase 7 单轮 matrix 抽测（EVALSHA==请求数、EVAL=0）
- **注意**：handler.lua:17 注释提及 store 本体 Phase 8 清理——删除时同步该注释

### 3.2 docker-compose `KONG_NGINX_HTTP_LUA_SHARED_DICT`

- **代码位置**：docker-compose.yml:33
- **当前引用**：仅被 store.lua 的 `ngx.shared["kong_rl"]` 消费（3.1）；插件其余代码零引用（handler/algorithm/lease/redis/schema grep 无 shared）
- **建议**：随 3.1 一并删除该 env 注入（`worker_processes=2` 的注释保留）
- **验证**：compose 重启健康 + 上述回归

### 3.3 RL-DEBUG 热路径日志（7 处，全部 notice 级）

- **代码位置**：algorithm.lua:289（multi_grant）、316（multi_reject）、354（local_hit）、381（lease_grant）、410（lease_take_after_grant）、459（redis_grant）、480（local_fill）
- **当前引用**：Phase 6/7 的 **测试框架依赖**——matrix.sh 的 localHit/leaseGrant/multi 列、6.5/6.4 部分日志断言均 grep 这些标记
- **问题**：每请求 1 次 notice 日志 + 字符串拼接（Phase 1 实测日志背压曾致 p95 3.5s 尖刺）；生产默认不应输出热路径调试
- **建议**：降级为 `kong.log.debug`（KONG_LOG_LEVEL=debug 才输出）——**保留全部字段与标记**，测试脚本改为 debug 级运行或改断言口径；`redis.lua:436` NOSCRIPT warn、handler 429 notice/故障 err·warn **保留不动**（排查必需）
- **影响**：需同步 matrix.sh/相关 E2E 的日志级别假设（测试框架改动，随批次执行）；行为语义零变化
- **验证**：notice 级请求无 RL-DEBUG 输出；debug 级字段完整；matrix 单轮（KongCPU 对比）+ 故障回归

### 3.4 `LEASE_TTL_MS = 3600000`（algorithm.lua:21）

- **代码位置/引用**：单一定义、唯一消费点 algorithm.lua:371 → lease.grant → GRANT_LEASE 的 `PEXPIRE lkey`（redis.lua:279）
- **结论**：**保留常量**。无重复配置；配置化会引入 schema/校验/生命周期问题且 V1 无对应需求（design.md 冻结注明"Phase 5 引入 RETURN/max_lifetime 后该常量交还配置管理"）
- **语义澄清（必须保留）**：此 TTL 仅是 Redis **Lease 元数据记录**的过期时间，与本地库存归还/自动 RETURN 无关——文档不得将 PEXPIRE 描述为自动归还（Deferred）

### 3.5 其余审计结论（有证据项）

| 项 | 证据 | 结论 |
|---|---|---|
| Redis 连接管理 | redis.lua:655/701 `set_keepalive(10000,100)`；connect 双路径（单规则/多键） | ✓ 正常；无泄漏（Phase 7 长压无连接堆积） |
| EVALSHA/NOSCRIPT 自愈 | 仅 NOSCRIPT 触发 LOAD+重试恰一次；超时不触发 | ✓ 冻结已验证 |
| nil,err 处理顺序 | algorithm.lua:452 先判 nil 再解引用 | ✓（rule.md §9.1 问题A 已修） |
| Lua table 生命周期/内存增长 | lease.lua `leases` 表保留 CLOSED 记录、`_pools` 不删除 | V1 冻结（保留诊断）；随配置churn/高基数维度增长——P3，Phase 5 池回收一并处理 |
| 429/503 区分、Retry-After 封顶 | handler.lua D1/D2 实现完整 | ✓ |
| 配置热更新 | 指纹隔离实证（6.3） | ✓（旧池自然消亡语义） |
| 测试可重复性 | 全脚本独立 ns/FLUSHDB 约定；6.5 脚本已实测多次可重复 | ✓ |

**P0/P1：无**。

## 4. 生产化问题清单（仅列有代码证据者）

| # | 问题 | 代码证据 | 影响 | 等级 | 建议方案 | 验收标准 |
|---|---|---|---|---|---|---|
| 1 | store.lua 死代码 + compose shared-dict 残留 | algorithm.lua:10/483 不可达；compose:33 | 误导读者、32m 内存白占 | P3 | 批次 A 删除（§3.1/3.2） | 全回归绿 + EVAL=0 |
| 2 | RL-DEBUG notice 热路径日志 ×7 | algorithm.lua 7 处 | 高并发日志 CPU/IO 开销；生产噪声 | P3 | 批次 B 降级 debug | notice 无输出、debug 字段完整、回归绿 |
| 3 | README/architecture 描述过时（store.lua/shared dict/旧库存语义） | README.md:26/205、architecture.md:13/65/72 | 误导部署与维护 | P3 | 批次 C 文档重写对齐 V1 | 文档与代码/报告一致 |
| 4 | CLOSED 记录与 `_pools` 永不清理 | lease.lua `leases`/`_pools` 生命周期 | 长时运行内存缓慢增长（高基数维度） | P3 | **Deferred**（Phase 5 池回收/RETURN 接线一并），V1 不动 | —（列入已知限制） |
| 5 | `LEASE_TTL_MS` 硬编码 | algorithm.lua:21 | 无实际影响 | P3（保留） | 不配置化（§3.4） | — |
| 6 | `1113.json` 未跟踪文件 | 工作区 | 仓库整洁 | P4 | 会话导出，本地保留不入库（.gitignore 可选） | 工作区声明 |

## 5. 清理分阶段计划（每批次独立 commit + 独立回滚）

### 批次 A：Legacy 库存实现清除
- **修改文件**：删除 `lib/store.lua`；`algorithm.lua`（去 require + 死代码块 480–484）；`docker-compose.yml`（去 shared-dict env）；`handler.lua:17` 注释措辞同步；README/architecture 涉 store/shared 的行
- **目的**：消除废弃实现与配置残留
- **允许范围**：上述文件中仅与 store/shared 相关行
- **禁止范围**：三条请求路径语义、Lease/redis/协议、batch 语义、指纹规则、schema 字段
- **测试**：全回归（§3.1 清单）+ 单轮 matrix（EVALSHA==请求数、EVAL=0、leaseGrant 比例不变）
- **验收**：回归全绿；`grep -r store kong/plugins` 零引用；compose 起停正常
- **回滚**：`git revert` 该 commit（单 commit 单主题）

### 批次 B：RL-DEBUG 日志降级
- **修改文件**：`lib/algorithm.lua`（7 处 notice→debug；保留字段与标记）；受影响的测试脚本日志级别/断言（matrix.sh `-L` 默认或 E2E grep 口径——**测试框架改动，不改生产语义**）
- **目的**：消除热路径 notice 开销，保留 debug 级可诊断性
- **禁止范围**：NOSCRIPT warn、429 notice、故障 err/warn、日志字段内容
- **测试**：notice 级下请求日志零 RL-DEBUG；debug 级字段完整；handler-fault-e2e 26 + 一轮 matrix（KongCPU 对比记录）+ 全回归
- **回滚**：revert

### 批次 C：文档与交付完善
- **修改文件**：README.md（架构/部署/配置/测试/已知限制重写）、docs/architecture.md（V1 架构图：Lease 模型）、docs/docker-mirror.md 如涉及
- **目的**：让其他开发者可理解、部署、测试、维护
- **禁止范围**：不得宣称 Deferred 能力已实现；不得改冻结结论
- **测试**：文档引用路径逐条检查 + 无代码 diff
- **回滚**：revert

### 批次 D：终验与收尾
- `git diff --check`、tasks.md Phase 8 勾选（7.3 矩阵核对已随 7.3 完成）、最终 commit `refactor: remove legacy local inventory implementation`（若 A–C 分批则此为总结 commit 或由 A 承担，按届时审查定）

## 6. 延期事项（不属于本次 V1 清理，不得写成已完成）

- **自动 RETURN**（RETURN_LEASE Lua 已实现、V1 不接线）
- **Worker 接管 / Lease 自动补偿 / 库存回补**
- **idle scanner / max_lifetime**（本地池回收属其范畴）
- **Redis Cluster 适配**（脚本缓存按节点、多键同 slot）与其性能验证
- **Redis HA/主从切换**下的行为验证
- **长时间稳定性压测（>24h）与内存曲线**
- **Prometheus 指标导出 / Tracing**（`_counters` 仅为内部基础）
- **p99 隔离环境重测**（Phase 7 NOT VERIFIED 项）

## 7. 最终交付清单（Phase 8.2+ 尚需）

| 项 | 现状 | 待办 |
|---|---|---|
| README | 过时（store/shared/旧语义） | 批次 C 重写：功能、三路径、部署（compose/生产要点）、配置字段表、测试入口、已知限制引用 §6 |
| 架构说明 | architecture.md 旧模型 | 批次 C 重绘：Worker Local Lease 模型、Redis 职责、故障语义 |
| 部署说明 | 缺生产要点 | 批次 C：Redis 依赖/超时/fault_tolerant 取舍/TTL 语义/升级注意（引用 Phase 6.6 §16） |
| 配置说明 | schema 散见 | 批次 C：字段表 + batch 权衡（损失敞口）+ limit_by 基数风险 |
| 测试说明 | 脚本齐 | 批次 C：分类索引（单测/E2E/故障/性能）+ 可重复执行口径 |
| 性能报告 | ✓ Phase 7 | 已交付 |
| 已知限制 | Phase 6.6 §13–§14 | 批次 C 在 README 汇总引用 |
| 面试讲解材料 | Phase 6.6 §17 结论具备 | 可选：单独讲解文档（决策链+数据） |

---

*本报告基于 HEAD `bc46c8c` 实际代码与全仓库引用分析生成；审计过程零代码/配置/文档修改。*
