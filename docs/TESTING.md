# 测试说明（运行索引与前置条件）

> 测试分为四层：**resty 协议级单测**（在 kong1 容器内执行）、**Redis Lua 协议矩阵**（redis-cli 直跑）、
> **真栈 E2E**（真实 Kong + Redis + HTTP）、**性能矩阵**（k6）。
> 各脚本断言数以 `docs/reports/` 各阶段报告为准；本文只给运行方式与前置条件，**历史 PASS 数量不代表
> 一次命令即可全部复现**——请按下述前置条件准备环境后逐个运行。

## 0. 前置条件

```bash
docker compose up -d            # 3×kong + redis + echo 全部健康
curl -s http://localhost:8031/status          # kong1 管理面 200
docker compose exec -T redis redis-cli ping   # PONG
```

- 单测脚本自动 `docker compose cp` 到 kong1 内用 resty 执行 ⇒ 必须先起栈
- E2E 脚本自带独立 namespace/配置下发/前置检查；部分脚本会 stop/start redis 或 kill -9 Worker
  （跑完自动恢复），**不要与其他测试并行**（有 FLUSHDB/环境互扰风险，串行执行）
- 性能矩阵默认以 `KONG_LOG_LEVEL=debug` recreate Kong（统计列依赖），结束自动恢复 compose 默认

## 1. resty 协议级单测（kong1 容器内）

| 命令 | 覆盖 | 最近一次全绿断言数 |
|---|---|---|
| `bash test/lease-unit.sh` | Lease Manager：TAKE/登记/CLOSED/四分类/账目守恒/无 yield | 25 |
| `bash test/algorithm-lease-unit.sh` | 三模式决策矩阵（transport stub 驱动真实 check_lease） | 17 |
| `bash test/config-isolation-unit.sh` | 策略指纹五维度 + 本地 Pool 隔离 | 15 |
| `bash test/evalsha-unit.sh` | EVALSHA 管理：NOSCRIPT 恰一次重试/超时不触发 LOAD | 8 |

## 2. Redis Lua 协议矩阵

| 命令 | 覆盖 |
|---|---|
| `bash test/lease-redis-matrix.sh` | GRANT_LEASE/RETURN_LEASE/GRANT_MULTI/TOKEN_BUCKET 协议级 50 项（redis-cli 直跑；Phase 7 期间 50/0 复核通过） |
| `bash test/lease-grant-smoke.sh` | GRANT 冒烟 |

## 3. 真栈 E2E（每项独立 namespace，串行执行）

| 命令 | 覆盖 |
|---|---|
| `bash test/handler-fault-e2e.sh` | 故障双路径：stop redis / CLIENT PAUSE 超时；batch=1 与 batch>1；双 Worker 库存（26 断言） |
| `bash test/fault-recovery-e2e.sh` | 故障恢复：连接拒绝→恢复、CLIENT PAUSE→恢复；无重复授权（12 断言） |
| `bash test/concurrent-lease-e2e.sh` | 多 Worker 并发 TAKE/GRANT、全局不超发、Worker 分布（17 断言） |
| `bash test/lease-exhaustion-e2e.sh` | Lease 耗尽 → CLOSED → 新 GRANT；多 Lease 并存（11 断言） |
| `bash test/worker-crash-e2e.sh` | kill -9 目标 Worker（inode→PID 实证）+ 库存损失账目（16 断言） |
| `bash test/lease-timeout-uncertain-e2e.sh` | GRANT 超时三态：未执行/已执行响应丢失/granted=0（22 断言） |
| `bash test/config-isolation-e2e.sh` | 配置变更真栈隔离（14 断言） |
| `bash test/algorithm-lease-e2e.sh` | Lease 路径真栈行为（15 断言） |
| `bash test/script-cache-selfheal-e2e.sh` | SCRIPT FLUSH 后三模式 NOSCRIPT 自愈（15 断言） |
| `bash test/lease-isolation.sh` | Lease 隔离历史回归 |

## 4. Bench 正确性回归（bench/）

| 命令 | 覆盖 |
|---|---|
| `bash bench/quota.sh -l 100 -b 1 -p 150` | batch=1 多副本严格配额（450 请求恰 100） |
| `bash bench/quota.sh -l 100 -b 20 -p 150` | batch=20 区间 [40,100] |
| `bash bench/dims.sh` | 七维度回归（8 断言） |
| `bash bench/rules.sh` | 多规则全或无等 5 场景（14 断言） |

## 5. 性能矩阵

```bash
bash bench/matrix.sh                       # 默认：BATCHES=10,50,100；RATES=100,500,1000；DUR=20s；debug 级
bash bench/matrix.sh -b 10                 # 仅 batch=10 组（Phase 7/8 抽测口径）
bash bench/matrix.sh -w 1                  # Worker=1（自动 recreate 并在结束恢复）
bash bench/matrix.sh -L notice             # notice 级（此时统计列为 0，属预期）
```

- 产物：`bench/out/results-<TAG>-w<W>-<level>-<rhost>.md` + k6 json `bench/out/<TAG>-w*.json`
- 采集：Redis commandstats/cpu、Kong 日志行（**需 debug 级**）、cgroup cpu.stat；污染轮（p99>500ms 或
  RPS<95%）自动重跑至多 3 次，全部轮次保留
- **正式性能结论以 `docs/reports/PHASE7_PERFORMANCE_REPORT.md` 为准**（原始数据 `bench/raw/phase7/`）；
  其他任何单轮运行仅作行为验证，不与 Phase 7 混用

## 6. 测试环境清理

```bash
docker compose down -v                     # 完全重置（E2E 中的 stop/kill 动作脚本会自动恢复）
docker compose up -d --force-recreate kong1 kong2 kong3   # 重载插件代码后重跑前执行
```

- 串行提醒：dims.sh/rules.sh 场景间有 FLUSHDB；与 E2E 并行会互清状态
- E2E 脚本偶发失败先重跑一次再归因（宿主机存在 ~4s 环境噪声，已知现象）

## 7. 历史测试报告索引

| 阶段 | 报告 |
|---|---|
| Phase 0 | docs/PHASE0_REVIEW.md、docs/review-phase-0.md |
| Phase 1 | test/phase1-manual.md（历史口径：RL-DEBUG 当时为 notice 级）、docs/results.md（Legacy 性能基线） |
| Phase 2 | docs/PHASE2_REVIEW.md、test/phase2-manual.md |
| Phase 3 | docs/PHASE3_GROUP1_REPORT.md、reports/phase-3-multi-rule.md |
| Phase 4 | docs/PHASE4_WORKER_LEASE_REPORT.md |
| Phase 6 | docs/PHASE6_REQUEST_INTEGRATION_REPORT.md、docs/reports/PHASE6_3/6_4/6_5_REPORT.md |
| Phase 7 | docs/reports/PHASE7_PERFORMANCE_REPORT.md + bench/raw/phase7/ |
| Phase 8 | docs/reports/PHASE8_CLEANUP_PLAN.md、PHASE8_A_LEGACY_CLEANUP_REPORT.md、PHASE8_B_LOG_CLEANUP_REPORT.md |

**历史口径说明**：phase1-manual.md / phase2-manual.md 中部分操作依赖当时为 notice 级的
RL-DEBUG 日志；当前热路径 RL-DEBUG 已降级 debug（Phase 8.2-B），复现该类日志统计需
`KONG_LOG_LEVEL=debug`。历史步骤与结论原样保留。
