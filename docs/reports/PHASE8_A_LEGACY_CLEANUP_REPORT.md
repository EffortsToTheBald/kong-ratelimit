# Phase 8.2-A 报告：Legacy shared-dict 库存实现清除

- **日期**：2026-11-14
- **基线 HEAD**：`3db8788`（Phase 8.1 审计提交）
- **commit**：`refactor: remove legacy shared-dict inventory implementation`

## 1. 修改前后代码结构

- **前**：handler→algorithm→{lease, redis, **store**}；store.lua（87 行 shared-dict 聚合库存）被 algorithm.lua:10 require、:483 `store.fill` 调用（调用链已证不可达：batch>1 于 algorithm.lua:453 转 check_lease）；compose 注入 `KONG_NGINX_HTTP_LUA_SHARED_DICT: kong_rl 32m`
- **后**：handler→algorithm→{lease, redis}；store 引用清零；compose 无 shared-dict 注入

## 2. 删除文件与代码清单

| 项 | 位置 |
|---|---|
| **整文件删除** | `kong/plugins/rate-limit-advanced/lib/store.lua`（87 行） |
| require 删除 | algorithm.lua:10 `local store = require ...` |
| 死代码块删除 | algorithm.lua 原 :477–485（`if batch > 1 and granted.granted > 1 then ... store.fill ... end` 含 local_fill 日志），替换为单行注释"batch=1：本请求恰好消耗 granted=1 中的 1 个，无本地库存（batch>1 已在上方转 check_lease）"；`ttl_s` 保留（:436 ttl_ms 仍消费） |
| compose 删除 | `KONG_NGINX_HTTP_LUA_SHARED_DICT: "kong_rl 32m"` + 相关注释 2 行；worker 注释措辞更新（"让 shared dict 的行为可复现"→"让压测/诊断行为可复现"） |
| 注释同步 | handler.lua:17 过时注释（"store 本体 Phase 8 清理"）→ 已随批次 A 移除声明 |

## 3. Compose 配置变化

- 删除 1 个环境变量（shared dict 注入）；其余（worker 数、Redis、Kong 服务、其他 env）未动；`docker compose config -q` 语法通过。

## 4. 文档修改清单（仅 Legacy store/shared 相关）

| 文件 | 修改 |
|---|---|
| README.md | 文件树：store.lua → lease.lua（补 lease.lua/多规则说明）；§8 已知限制：shared dict 描述 → Lease 预授权语义；§9 故障表：unknown directive 行更新（不再依赖 shared dict） |
| docs/architecture.md | 表 0："本地库存"行 → Worker 私有 Lua table（不依赖 shared dict）；"远程批量租约"行 → EVALSHA 三脚本；mermaid classDef `store`→`conn`（仅样式命名） |

## 5. 测试执行结果（串行，全实际执行）

| 测试 | 命令 | PASS | FAIL |
|---|---|---:|---:|
| Lease Manager 单测 | `bash test/lease-unit.sh` | 25 | 0 |
| algorithm Lease 路径单测 | `bash test/algorithm-lease-unit.sh` | 17 | 0 |
| algorithm Lease E2E | `bash test/algorithm-lease-e2e.sh` | 15 | 0 |
| 配置隔离单测 | `bash test/config-isolation-unit.sh` | 15 | 0 |
| 配置隔离 E2E | `bash test/config-isolation-e2e.sh` | 14 | 0 |
| handler 故障双路径 | `bash test/handler-fault-e2e.sh` | 26 | 0 |
| quota batch=1 | `bash bench/quota.sh -b 1` | 100/350/0 严格 | 0 |
| quota batch=20 | `bash bench/quota.sh -b 20` | 99/351 ∈[40,100] | 0 |
| dims 维度回归 | `bash bench/dims.sh` | 8 | 0 |
| rules 多规则 | `bash bench/rules.sh` | 14 | 0 |
| 6.5 并发 | `bash test/concurrent-lease-e2e.sh` | 17（首轮 1 偶发失败，连跑 2 次全绿；与本次清理无关的环境波动） | 0 |
| 6.5 耗尽重申请 | `bash test/lease-exhaustion-e2e.sh` | 11 | 0 |
| 6.5 kill -9 账目 | `bash test/worker-crash-e2e.sh` | 16 | 0 |
| 6.5 超时不确定 | `bash test/lease-timeout-uncertain-e2e.sh` | 22 | 0 |

**合计 236 PASS / 0 FAIL / NOT RUN：无**（批次 A 清单全项执行）。

## 6. Docker Compose 验证

- `docker compose config -q` ✓；`up -d --force-recreate kong1/2/3` 后三节点 `/status` 200、Redis PING、kong1 worker 数=2、日志无 `unknown directive`。
- 限流请求验证：batch=10 配置（独立 ns）连发 3 请求全 200。

## 7. 性能抽测（单轮，非 Phase 7 正式结果）

`bash bench/matrix.sh -T p8acheck -b 10`（结果表归档 `bench/raw/phase7/results-p8acheck-w2-notice-redis.md`）：

| 检查 | 结果 |
|---|---|
| batch=1：EVALSHA == 200 数 | ✓ 干净轮 20001=20001（@1000/@500/@100 全一致） |
| batch>1：leaseGrant ≈ 请求数/10 | ✓ @1000: 2002/20001、@500: 1003/10001、@100: 203/2000 |
| **Legacy EVAL 次数** | **0**（87+ 行全量求和） |
| SCRIPT_LOAD 次数 | 0（脚本缓存无失效） |
| localHit ≈ 90% 请求本地消费 | ✓（1798+8998+17998 量级一致） |
| 不再依赖 shared-dict 库存 | ✓（EVAL=0 且 store 引用清零 + compose 无注入） |

- 本轮宿主机 4s 环境噪声较重（B@500 三次尝试均被污染，原始数据保留于结果表）；抽测仅确认清理未破坏行为，**不与 Phase 7 三轮正式结果混用**。
- 抽测指标与 Phase 7 干净轮均值同量级（b1 RedisQPS 4787 vs 4773；b10 EVALSHA 2002 vs 2002）。

## 8. 与 Phase 7 基线关键指标对照

| 指标（@1000 干净轮） | Phase 7 | 本批抽测 | 判定 |
|---|---|---|---|
| b1 EVALSHA/200 数 | 20001=20001 | 20001=20001 | 一致 |
| b1 RedisQPS | 4773 | 4787 | 同量级 |
| b10 leaseGrant/请求数 | 2002/20001 | 2002/20000 | 一致（9.99:1） |
| b10 localHit | 17998 | 17998 | 一致 |
| EVAL / SCRIPT_LOAD | 0 / 0 | 0 / 0 | 一致 |
| p50/p95（b10） | 0.50/1.16 | 0.48/1.09（r100 干净轮 1.09/1.91→@1000 0.48 量级一致） | 同量级 |

## 9. 未验证事项

- 单轮抽测的延迟数据受本轮环境噪声影响较重，不作为性能结论（Phase 7 三轮为正式口径）。
- 禁止范围内文件（lease.lua/redis.lua/schema.lua/Lua 协议/batch 语义）零改动，未做专项测试（无改动即无需）。

## 10. 核心请求路径语义声明

**未改变**：batch=1 逐请求 Redis 授权、batch>1 GRANT_LEASE+Worker 本地 TAKE、多规则 GRANT_MULTI 全或无、Fail-close/降级双路径、429/503 语义、Retry-After、策略指纹与 Key 设计、Lua 协议、Lease Manager——本批次仅移除已证明不可达的 Legacy 实现与配置残留。

---

*静态检查：`grep store kong/plugins --include=*.lua` 仅剩 handler.lua 历史注释一行；`kong_rl`/`LUA_SHARED` 全仓清零（历史报告中的文字记录按约定不属有效代码引用）。*
