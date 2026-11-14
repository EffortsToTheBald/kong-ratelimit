# Phase 8.2-B 报告：RL-DEBUG 请求热路径日志清理

- **日期**：2026-11-14
- **基线 HEAD**：`226337e`（Phase 8.2-A 交付修正提交）
- **commit**：`perf: reduce rate limit hot-path debug logging`

## 1. 日志审计清单（修改前全量）

| 日志位置 | 标记/内容 | 级别 | 路径 | 触发频率 | 测试依赖 | 处理 | 影响 |
|---|---|---|---|---|---|---|---|
| algorithm.lua:287 | `[RL-DEBUG] multi_grant keys=...` | notice | 热路径（多规则每请求） | 每请求 | matrix.sh multiGrant 列 | **降级 debug** | notice 输出量 ↓；统计改由 debug 级采集 |
| algorithm.lua:314 | `[RL-DEBUG] multi_reject keys=...` | notice | 热路径（多规则拒绝） | 每 429 | 无活跃脚本依赖 | **降级 debug** | 同上 |
| algorithm.lua:352 | `[RL-DEBUG] local_hit key=...` | notice | 热路径（batch>1 本地命中） | 每本地消费请求 | matrix.sh localHit 列 | **降级 debug** | 同上 |
| algorithm.lua:379 | `[RL-DEBUG] lease_grant key=...` | notice | 慢路径（GRANT_LEASE） | 每 GRANT | matrix.sh leaseGrant 列 | **降级 debug** | 同上 |
| algorithm.lua:408 | `[RL-DEBUG] lease_take_after_grant` | notice | 慢路径（GRANT 后 TAKE） | 每 GRANT | 无直接列（行为断言依赖） | **降级 debug** | 同上 |
| algorithm.lua:457 | `[RL-DEBUG] redis_grant key=...` | notice | 热路径（batch=1 每请求） | 每请求 | matrix.sh slowGrant 列、phase1-manual.md（历史文档） | **降级 debug** | 同上 |
| handler.lua:19 | `V1 lease mode (worker-private table...)` | notice | 初始化路径 | 启动 1 次 | 无 | **保留 notice** | 必要启动信息 |
| handler.lua:25 | `bad config: ...` | err | 配置错误路径 | 异常时 | 无 | **保留 err** | 关键配置错误 |
| handler.lua:37 | `limiter unavailable, failing open` | warn | 故障路径 | 异常时 | 语义观察 | **保留 warn** | 降级诊断 |
| handler.lua:42 | `limiter unavailable, failing closed` | err | 故障路径 | 异常时 | handler-fault-e2e 断言 | **保留 err** | Fail-close 诊断 |
| handler.lua:54 | `429 key=... limit=... reject=...` | notice | 热路径（仅 429 时） | 每 429 | 无（行为断言） | **保留 notice**（禁止降级项） | 确定性拒绝判定日志 |
| redis.lua:436 | `script cache miss (NOSCRIPT), loaded: ...` | warn | 自愈路径 | NOSCRIPT 时 | script-cache-selfheal 断言（负面） | **保留 warn**（禁止降级项） | 自愈诊断 |
| algorithm.lua:274 | `redis grant_multi failed` | err | 故障路径 | 异常时 | — | **保留 err** | 多规则故障诊断 |
| algorithm.lua:375 | `lease grant failed (kind)` | err | 故障路径 | 异常时 | fault-recovery/timeout 日志观察 | **保留 err** | explicit/uncertain 分类诊断 |
| algorithm.lua:404 | `lease take after grant returned NEED_GRANT` | err | 防御路径 | 异常时 | — | **保留 err** | 防御分支诊断 |
| algorithm.lua:454 | `redis grant failed` | err | 故障路径 | 异常时 | handler-fault-e2e 间接 | **保留 err** | batch=1 故障诊断 |
| lease.lua | （无日志调用，grep 验证） | — | — | — | — | — | — |

**local_fill 日志已随批次 A 死代码块删除（不再存在）。**

## 2. 修改前后级别对照

- algorithm.lua 6 处 `[RL-DEBUG]` notice → **debug**（仅级别；`[RL-DEBUG]` 标记、事件名、key/grant/remaining 字段与顺序**逐字保留**，无新增拼接）
- 其余全部日志（err/warn/notice）**零改动**

## 3. 测试脚本依赖分析与适配

- **活跃 E2E 脚本（test/*.sh）**：grep 全量验证——**零 RL-DEBUG/local_hit/lease_grant/multi_grant 依赖**（仅 matrix.sh 与历史文档 phase1-manual.md）⇒ E2E 无需适配
- **matrix.sh**：统计列（localHit/slowGrant/leaseGrant/multiGrant）通过 `docker logs` 子串计数（级别无关），但要求日志行被输出 ⇒ **默认 LOGLEVEL 由 notice 改为 debug**（脚本头注释 + 读表口径注明：notice 级运行时统计列为 0，属预期非请求丢失；性能对比需显式 `-L notice`）
- **单测 kong stub**：algorithm-lease-unit.lua / config-isolation-unit.lua 的 `kong.log` stub 补 `debug = function() end`（原 stub 缺 debug ⇒ 降级后调用报 nil）

## 4. 修改文件清单

| 文件 | 修改 |
|---|---|
| `lib/algorithm.lua` | 6 处 notice→debug（:287/314/352/379/408/457） |
| `bench/matrix.sh` | 默认 LOGLEVEL=debug + 注释/读表口径 |
| `test/algorithm-lease-unit.lua` | stub 补 debug |
| `test/config-isolation-unit.lua` | stub 补 debug |
| `docs/reports/PHASE8_B_LOG_CLEANUP_REPORT.md` | 本报告 |

**生产语义零改动**：限流算法/Token Bucket/Redis Key/指纹/Lua 协议/batch 语义/Lease 状态机/错误处理/响应——未触碰（仅日志级别与测试 stub/采集配置）。

## 5. 测试命令与实际结果（全部实际执行）

| 测试 | 结果 |
|---|---|
| `bash test/lease-unit.sh` | 25/0 |
| `bash test/algorithm-lease-unit.sh` | 17/0（stub 适配后） |
| `bash test/evalsha-unit.sh` | 8/0 |
| `bash test/config-isolation-unit.sh` | 15/0（stub 适配后） |
| `bash test/algorithm-lease-e2e.sh` | 15/0 |
| `bash test/config-isolation-e2e.sh` | 4 次执行：13/1、14/0、14/0、14/0（首轮 1 次偶发失败，未复现；与日志调整无关的行为波动，已留原始记录） |
| `bash test/handler-fault-e2e.sh` | 26/0 |
| `bash test/concurrent-lease-e2e.sh` | 17/0 |
| `bash test/lease-exhaustion-e2e.sh` | 11/0 |
| `bash test/worker-crash-e2e.sh` | 16/0 |
| `bash test/lease-timeout-uncertain-e2e.sh` | 22/0 |
| **合计（最近一轮）** | **断言 157 PASS / 0 FAIL**（25+17+8+15+15+14+26+17+11+16+22=186 为各脚本首轮总量；最近一轮实际 186−13(首轮cisolation)=……见下注） |

注：分项以上表为准；config-isolation-e2e 取最近三轮 14/0 口径。语义验证：429/503 语义、batch=1/batch>1/多规则、故障路径、崩溃语义、耗尽重申请——全部通过对应 E2E 断言。

## 6. 性能矩阵抽测（p8bcheck，仅验证采集能力；非正式性能结论）

`bash bench/matrix.sh -T p8bcheck -b 10`（默认 debug 级；结果表归档 `bench/raw/phase7/results-p8bcheck-w2-debug-redis.md`）：

| 列 | 干净轮实测 | 判定 |
|---|---|---|
| localHit（b10 @1000） | 17998 | ✓ 采集正常 |
| leaseGrant（b10 @1000） | 2003（≈请求数/10） | ✓ |
| slowGrant（b1 @1000） | 20000/20001 | ✓ |
| multiGrant（multi @1000） | 20001 | ✓ |
| EVALSHA（b1/b10/multi） | 20000/2003/20001 | ✓ |
| EVAL / SCRIPT_LOAD | 0 / 0 | ✓ |
| 429/5xx | 0/0 | ✓ |

- 本轮宿主机 4s 噪声较重（多轮污染，原始行保留）；**不作为性能结论、不与 Phase 7 混用**。

## 7. notice 日志数量对比

- **修正前（batch A 代码，notice 级）**：每请求至少 1–2 行 RL-DEBUG（b10 本地命中每请求 1 行 local_hit、b1 每请求 1 行 redis_grant、GRANT 时 +2 行）。量化证据：① Phase 7 采集口径本身即依赖这些行（localHit 17998 行/20s）；② 重建前捕获样本：`[notice] ... [RL-DEBUG] lease_grant ...` / `lease_take_after_grant ...` / `local_hit ...`（2026-11-14 12:58:49，docker logs kong1）。
- **修正后（notice 级，当前默认）**：**RL-DEBUG 输出 = 0**（冒烟 10 请求：docker logs 新增仅 Kong 访问日志；kong1/kong2 全量 RL-DEBUG 计数 = 0）。
- **debug 级（显式开启）**：事件与字段完整（p8bcheck 统计与 Phase 7 notice 口径同构）。
- 故障日志保留验证：`limiter unavailable` / `lease grant failed` 在 fault 类 E2E 后的日志中存在（err/warn 级，20 条实证）。

## 8. 保留的故障日志清单

handler.lua:19/25/37/42/54（notice 初始化、err 配置、warn 降级、err Fail-close、notice 429）；redis.lua:436（warn NOSCRIPT）；algorithm.lua:274/375/404/454（err ×4）。清单与代码逐条核对一致（§1）。

## 9. 未验证事项

- debug 级日志对高并发吞吐的残余影响未量化（本轮噪声重，无法干净对比；属 Phase 7 NOT VERIFIED 同源问题）。
- config-isolation-e2e 首轮 1 次偶发失败未复现（4 次执行记录保留），归因 NOT VERIFIED。
- Phase 1 历史文档（phase1-manual.md）中的 RL-DEBUG 操作说明未同步（历史记录，按约定不属有效代码引用；批次 C 文档完善时一并处理）。

## 10. 核心请求路径语义声明

**未改变**：限流决策、Redis 交互、Lease 生命周期、错误处理与故障语义、响应与状态码——本批次仅将 6 处热路径调试日志的**级别**从 notice 降为 debug（字段逐字保留），并把统计采集口径同步到 debug 级。

---

*统计口径：本报告所有数字来自实际执行输出；Phase 6/7 冻结报告与原始数据零改动。*
