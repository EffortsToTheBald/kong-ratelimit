# 手动测试记录 —— Phase 1 核心正确性基线（first-commit）

**日期**：2026-11-11
**执行人**：项目作者（按手动测试剧本逐 case 执行）
**结论**：✅ **全部通过**（环境准备 + 11 个 case，无失败项）
**对应变更**：`openspec/changes/phase1-correctness-baseline`（22/22 任务，commit 链 `3d06fdf..41b10f9`）
**自动化验收报告**：`reports/phase-1-correctness.md`（本文档为该报告的人工复核记录）

---

## 0. 环境准备与隔离前奏

- `docker compose ps`：5 容器 running/healthy；`redis-cli ping` → PONG ✅
- **隔离前奏**（每个 Case 前执行）：`restart kong1 kong2 kong3` → 等 `/status` 200 → `FLUSHDB`
- 结束后 `restart kong×3` 即恢复 `kong.yml` 初始配置（limit=1000/60s，batch=auto，fault_tolerant=false）

## 1. Case 结果总表

| # | Case | 验收要点 | 结果 |
|---|---|---|---|
| 1 | 单节点基础令牌桶（limit=5/60s） | 前 5 个 200、第 6 个起 429；429 带 `Retry-After`（≈11~12s）与 `X-RateLimit-*` 头 | ✅ |
| 2 | batch=1 三节点严格配额 | 100/350/0；每节点 150 断言过；日志 `local_hit=0`、`local_fill=0`、`redis_grant=450` | ✅ |
| 3 | batch=20 不超发与下界 | allowed ∈ [40,100] 且永不超 100；隔离协议下稳定在 100，历史波动不复现 | ✅ |
| 4 | 跨配置隔离（策略指纹） | 同 namespace 切 limit 1000→100 后恰放行 ≤100（修复前同场景 116）；KEYS 出现两个不同 `p=` 桶 | ✅ |
| 5 | Redis 故障默认 Fail-Closed | 503 `rate limiter unavailable`；无上游响应头；日志 `failing closed`，无 traceback/500 | ✅ |
| 6 | 显式容错 degraded | 200 + `X-RateLimit-Status: degraded` + 已达上游；恢复后无标记；日志 `failing open` | ✅ |
| 7 | 令牌补充（rate=1/s） | 耗尽后等 5s 恰 4~5 个 200（=⌊elapsed×rate⌋）；桶 tokens ≤ burst=60 | ✅ |
| 8 | 时间回拨不重复计费 | 预置未来 ts → 请求后 tokens −1、**ts 保持未来值不被覆盖**、无补充 | ✅ |
| 9 | 伪造 XFF 不换桶 | `bench/xff.sh`：200=1、429=19、PASS | ✅ |
| 10 | namespace 轮次隔离 + 每节点断言 | 两轮 namespace 段不同、同策略指纹一致（e891f3c2）；断言 10/10/10 通过 | ✅ |
| 11 | 指纹性质（10 断言） | `FINGERPRINT_PROPS_OK base=25c15179 limit1000=8039753e` | ✅ |

## 2. 期望值锚点（供未来回归对比）

| 项 | 值 |
|---|---|
| 指纹 limit=100/window=3600/burst→100/limit_by=ip,path | `25c15179` |
| 指纹 limit=1000/…/limit_by=ip | `8039753e` |
| 指纹 limit=100/…/limit_by=ip | `50780f62` |
| 指纹 limit=1000000/…/limit_by=ip | `e891f3c2` |
| key 格式 | `kong:rl:{<ns>:p=<8位hex>:ip=172.20.0.1}` |
| batch=1 基线（450 请求） | allowed=100 / limited=350 / other=0 / redis_grant=450 |
| batch=20 基线（隔离协议下） | allowed=100（区间 [40,100]） |
| 补充速率（limit=60/60s） | 5.004s → 5 个令牌 |
| 故障日志锚点 | `algorithm.lua:136 grant failed` → `handler.lua:29 failing open` / `handler.lua:34 failing closed` |

## 3. 执行要点（复现时注意）

1. **每个 Case 必须先做隔离前奏**——同策略下 FLUSHDB 后旧本地库存仍有效（合法语义、少发方向），不清 worker 库存会污染数字（实测出现过"90 请求全走旧库存、未建 Redis 桶"）。
2. Case 4 不能用 `quota.sh`（它会每轮换 namespace），需 `source bench/common.sh` 后手工 `apply_config` + curl 循环，保持同一 namespace。
3. Case 6 的配置需显式带 `fault_tolerant: true`（`kong_config_json` 生成的配置已是显式 false，与默认一致）。
4. 手动耗尽阶段（Case 7）手速慢会多补几个令牌，验收按"≤ 60 + 耗时秒数"判断。
5. `bench/common.sh` 含 bash 数组，必须在 bash 中 source。

## 4. 提交链（每组一个 commit，组级可回滚）

```
41b10f9 组8: Phase 1 集成验收（测试 A-D + 报告）
5b33762 组7: IP 维度回归测试（bench/xff.sh）
912eab2 组6: 压测脚本收敛（namespace 隔离 + 每节点断言）
4dd3576 组5: Fail-Closed 默认（schema + kong.yml + 文档）
f830672 组4: 策略指纹进 Key（FNV-1a + 双桶隔离实测）
04cad54 组3: 决策主流程修复（nil 判定 / batch=1 短路 / get_ip）
f081647 组2: Redis Lua 时间戳单调（双源同步）
352b7fe 组1: 回滚基线与环境自检
3d06fdf baseline: P0 修复前回滚锚点
```

## 5. 遗留事项（下一 change 输入）

- `rule.md` §3.2/§3.3 key 格式示例尚未含 `p=` 指纹（作者原始文档，待作者确认后同步）
- P1 批：reset/remaining 口径（batch=1 时 Remaining 恒 0）、EVALSHA、Retry-After 上限、429 日志、Redis 返回值防御校验、header_name schema 校验、shared dict 降级告警
- Phase 4：batch×RPS 矩阵、非均匀流量滞留、本地库存租赁生命周期（须防重复归还）、`bench/out` 权限预检
- Phase 5：Prometheus 指标、结构化日志、长稳/节点重启场景

**人工验收：通过（本文档即验收记录）。**
