# Phase 8.2-C 审计报告：最终交付文档审计（第一轮）

- **日期**：2026-11-14
- **基线 HEAD**：`96575ee`（工作区干净，仅 `1113.json` 未跟踪）
- **性质**：只审计，不修改任何文件；等待人工确认审计范围后再进入文档整理

---

## 0. 审计范围与方法

- 通读：README.md（232 行全读）、docs/architecture.md（213 行全读）、docs/bench.md、docs/plan.md、docs/docker-mirror.md、docs/design.md（冻结）、docs/rule.md（冻结）、docs/results.md（Legacy 基线）、全部 Phase 报告、schema.lua 字段定义、handler/algorithm/lease/redis 当前实现、test/ 与 bench/ 脚本清单、docker-compose.yml、kong/kong.yml
- 方法：每条疑点对照当前代码/冻结报告核实（batch=auto 实测 `clamp(limit/50,1,50)=20`、quota.sh `-l/-b/-p` 参数真实存在、compose 端口 8030/8010/8020、k6 NODES 等）

## 1. 审计总表

| 文档 | 当前问题 | 目标调整 | 是否修改 |
|---|---|---|---|
| **README.md** | ① §6 性能矩阵命令过时（实际默认 BATCHES=10,50,100 / RATES=100,500,1000、产物 bench/out/results-\*.md 而非 bench/results.md；未提 leaseGrant 列与 debug 级统计口径）；② §7 验收清单"batch=20 p99 与基线差<1ms"无当前证据（Phase 7 环境 p99 底噪 ~80ms，属 NOT VERIFIED 口径）；③ §5 batch 表"典型 p99 增量"数值无当前实测（Phase 7 未测 5/20 档）；④ §0 设计一句话只覆盖 batch>1 预授权，未概括三模式；⑤ 缺三路径概览（batch=1/batch>1 Lease/多规则）与 EVALSHA 自愈说明；⑥ 缺配置字段系统表（散见各节）；⑦ 缺 test/ 全套测试运行说明与报告索引；⑧ 目录树缺 test/、redis/（双源）、docs/reports/ | 重写为面向新用户的完整 README（§5.1–5.8 口径），过时命令/数值以实测为准，性能引用 Phase 7 | ✅（第二轮） |
| **docs/architecture.md** | ① 图 1 mermaid 仍画 "POOL 本地库存·跨 worker 共享"、REPL "2 workers 共享同一份本地库存"——**与 V1 Worker 私有 Lease 矛盾（最重要过时点）**；② 图 2 决策流程缺 CLOSED/耗尽重申请/超时不确定→故障分支，"余量入本地池"为 Legacy 措辞；③ 图 3 SOLVED 区只到 Phase 3，OPEN 区 "Phase 4 EVALSHA/性能矩阵" 已完成（Phase 2/7）→ 过时；"调试日志为临时态"已被 8.2-B 处理；④ 表 1 部分"验证证据"为 Legacy 实现时代数据（如"授出 600=消耗90+本地510"），需标注历史口径；⑤ 表 2 未解决问题多条已完成（EVAL→EVALSHA Phase 2、性能矩阵 Phase 7）；⑥ 缺三模式差异表、Lease 生命周期（ACTIVE→CLOSED）、库存账目（granted=consumed+outstanding / lost）、EVALSHA 自愈、性能权衡（Phase 7 引用）；⑦ "租约/Lease/本地库存"术语混用 | 整理为当前实现架构文档（14 项清单见任务书 §六），历史证据标注时代，术语统一 Lease | ✅（第二轮） |
| **docs/DEPLOYMENT.md（新增）** | 部署信息散落 README §2/§3/§9 + compose 注释，无独立部署文档；缺环境依赖/服务检查/插件加载/Redis 验证/清理的系统说明；需明确 DB-less/Compose 验证环境 ≠ K8s/Cluster/生产 HA 验证 | 新增（含启动/检查/请求验证/Redis 验证/故障排查/清理；命令逐一与仓库核对） | ✅ 新增（第二轮） |
| **docs/CONFIGURATION.md（新增）** | Schema 字段无系统文档：limit/window/burst/limit_by/header_name/batch/rules/namespace/hide_client_headers/fault_tolerant/redis.\*（schema.lua 实测默认值齐备）；缺策略指纹/batch 权衡/LEASE_TTL_MS 非配置项说明 | 新增字段表（以 schema.lua 为准，不含不存在字段） | ✅ 新增（第二轮） |
| **docs/TESTING.md（新增）** | test/ 15+ 脚本无运行索引；缺环境前置（Docker/Kong/Redis 容器、compose 默认 notice 级）、各类测试的运行方式与清理要求；性能引用 Phase 7 | 新增（单测/Lua 矩阵/E2E/故障/隔离/配置隔离/性能分类索引） | ✅ 新增（第二轮） |
| **docs/bench.md** | §1 "worker 进程数 2 与 shared dict 行为相关"过时；"时长≥30s"与 Phase 7 实际 20s 口径不一致；四组实验协议为 Legacy 时代设计 | 更新为当前实验协议（Phase 7 实际口径），Legacy 段标注历史 | ✅（第二轮） |
| **docs/plan.md** | 4 天实施路线为早期历史计划，与实际演进（Phase 0–8.2）不符 | **保留为历史文档**，仅在头部加"历史计划，实际演进见 docs/reports/"说明 | ✅（仅加注） |
| **docs/docker-mirror.md** | 网络镜像拉取指南，仍有效 | 不动 | ❌ |
| **test/phase1-manual.md** | 含 RL-DEBUG notice 期操作口径（local_fill/redis_grant 计数）——8.2-B 报告已声明批次 C 处理 | 头部加"历史记录（Phase 1 时代口径）"说明，不改正文 | ✅（仅加注） |
| **test/phase2-manual.md** | 同上性质 | 同上加注 | ✅（仅加注） |
| **docs/plan.md 引用的 design.md 第 8/9 节（README §8 引用）** | 链接有效（design.md 存在） | 保持 | ❌ |
| **docs/design.md、rule.md、V1_SCOPE_ADJUSTMENT.md、docs/results.md、docs/PHASE0/2/3 报告、docs/PHASE4/6 报告、docs/reports/PHASE6_3/4/5/7/8_A/8_B、reports/phase-\*、docs/review-phase-0.md、openspec/\*** | 冻结材料/历史报告 | **全部保留原样** | ❌ |
| **docker-compose.mirror.yml / scripts/pull-images.sh / k6/\*.js / redis/\*.lua（双源）** | 无文档问题 | 在 README 目录树中补齐条目即可 | ❌（代码不动） |

## 2. 与当前代码不一致的过时点（逐项证据）

1. **README §6**：`./bench/matrix.sh  # 默认 batch 0,1,5,20 × RPS 200,1000`——实际 `BATCHES="${BATCHES:-10,50,100}"`、`RATES="${RATES:-100,500,1000}"`（matrix.sh:38-39）；产物 `bench/out/results-<TAG>-*.md`（matrix.sh:291），非 `bench/results.md`
2. **README §3 响应示例**：`X-RateLimit-Remaining: 997`——kong.yml 实际 limit=1000/window=60/batch=0(auto→20)；Lease 模式首个请求 remaining=granted−1（batch=20 时为 19，非 997）；示例需按当前实现重测后如实标注
3. **README §5 表**："batch=0 auto：clamp(limit/50,1,50)"——代码证实（algorithm.lua:167–175，与 kong.yml 注释一致 ✓ 保留）；"典型 p99 增量 ~0.3–1ms/≈0"——**无当前实测证据**（Phase 7 只测 batch=1/10/多规则，p99 底噪由环境支配），改为引用 Phase 7 实测并标注档位覆盖范围
4. **README §7**："batch=20 的 p99 与无插件基线差 < 1ms"——Phase 7 干净轮 M0 p99=12.6ms、b10=87.1ms，该断言不成立/无法归因（NOT VERIFIED）⇒ 必须重写
5. **architecture 图 1/图 2/图 3**：见总表 ①②③（跨 worker 共享库存、SOLVED 停留在 Phase 3、OPEN 区已完成项）
6. **bench.md §1**："worker 进程数 2 与 shared dict 行为相关"——shared dict 已移除（8.2-A）
7. **术语**：architecture.md"租约/租赁模式"、README"库存/租约"与冻结文档"Lease"混用 ⇒ 统一 Lease（引用历史原文时保留）

## 3. 内容重复

- README §5 多规则块 与 architecture 图 2 多规则分支 与 design.md 冻结内容重复——README 保留简要版并链接冻结文档
- 部署信息在 README §2/§3/§9 与 compose 注释分散 ⇒ 收敛到 DEPLOYMENT.md，README 保留快速启动并链接

## 4. 必要信息缺失（新增项）

1. 三模式差异对比表（README + architecture）
2. Lease 生命周期与库存账目（architecture）
3. 配置字段全表（CONFIGURATION.md）
4. 测试运行索引与环境前置（TESTING.md）
5. EVALSHA/NOSCRIPT 自愈说明（README 特性 + architecture 机制节）
6. 报告索引（docs/ 与 docs/reports/ 全部冻结材料的导航）
7. 生产边界与 Deferred 汇总（README §7 已知限制重写，引用 Phase 6.6 §14）

## 5. 夸大或证据不足（必须消除）

| 位置 | 表述 | 问题 |
|---|---|---|
| README §5 表"典型 p99 增量" | 数值级承诺 | 无当前实测 |
| README §7 | "p99 差<1ms" | 与 Phase 7 环境实测矛盾（NOT VERIFIED） |
| README §10 | "Redis 负载 ÷batch" | 措辞应引 Phase 7 实测（授权命令 20001→2002 约 9.99:1、总 QPS 5.5×） |
| architecture 表 1 | 部分数据为 Legacy 时代 | 需标注历史口径，不得冒充 Lease 实现 |
| （潜在风险）任何把 Lease TTL PEXPIRE 写成"自动归还"的表述 | — | 审计未发现现有表述如此，但第二轮整理时必须防范 |

## 6. 历史内容必须保留（不改）

- docs/results.md（Legacy 基线）、docs/PHASE0_REVIEW/PHASE2_REVIEW/PHASE3_GROUP1/PHASE4_WORKER_LEASE/PHASE6_REQUEST_INTEGRATION、docs/reports/PHASE6_3/6_4/6_5/7/8_A/8_B/8_CLEANUP_PLAN、docs/V1_SCOPE_ADJUSTMENT.md、docs/review-phase-0.md、docs/design.md、docs/rule.md、reports/phase-\*.md、test/phase1-manual.md、test/phase2-manual.md、bench/raw/phase7/
- 历史报告保持其产生时的事实；当前实现描述只写入 README/architecture/新文档

## 7. 第二轮计划（待人工确认后执行）

1. README.md 重写（§5.1–5.8 口径）
2. docs/architecture.md 整理（14 项清单）
3. 新增 docs/DEPLOYMENT.md、docs/CONFIGURATION.md、docs/TESTING.md
4. docs/bench.md 更新 + docs/plan.md、test/phase\*-manual.md 头部加历史注
5. 一致性审查（术语/设计/证据/链接）+ `docs/reports/PHASE8_C_DOCUMENTATION_REPORT.md`
6. `git diff --check` 后独立提交，停止等待审查

**修改文件范围预告**：README.md、docs/architecture.md、docs/bench.md、docs/plan.md（加注）、test/phase1-manual.md（加注）、test/phase2-manual.md（加注）、docs/DEPLOYMENT.md（新）、docs/CONFIGURATION.md（新）、docs/TESTING.md（新）、docs/reports/PHASE8_C_DOCUMENTATION_AUDIT.md（本报告）、docs/reports/PHASE8_C_DOCUMENTATION_REPORT.md（第二轮新增）。生产代码/测试脚本/Bench 脚本/冻结报告/原始数据零修改。
