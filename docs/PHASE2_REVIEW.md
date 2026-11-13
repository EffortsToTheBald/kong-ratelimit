# PHASE2_REVIEW —— EVALSHA 脚本管理审查与验收

> 审查对象：`e4dd6c8 feat: add evalsha script management` + `b700417`（清单同步）
> 核心代码：`lib/redis.lua`；单测：`test/evalsha-unit.sh/.lua`；性能：`bench/matrix.sh`、`docs/results.md`、`bench/out/results-p2-*`
> 审查依据：Phase 2 实施规范约束 + Phase 2 Spec/Design/Tasks + Phase 1 基线
> 审查日期：2026-11-13

## 1. 审查范围

- `lib/redis.lua` diff：新增脚本表（SCRIPTS）+ `is_noscript_err` + `load_script` + `evalsha` 包装（懒加载 + NOSCRIPT 重载重试恰一次）；`grant()/grant_multi()` 调用由 `r:eval` 切换为 `evalsha`。
- **业务决策逻辑零改动复核**：diff 中无 parse_*/refill/扣减/状态逻辑改动；四脚本双源一致性复核——TOKEN_BUCKET ✓、GRANT_MULTI ✓（diff 为空）。

## 2. 代码审查结论

### P0-1 EVALSHA 执行安全性 —— 通过

| 检查项 | 证据 |
|---|---|
| 仅明确 NOSCRIPT 触发 LOAD | `is_noscript_err` 为精确子串匹配（`find(err,"NOSCRIPT",plain)`）；超时/断开/普通错误串不含该词 |
| LOAD 后重试恰一次、二次 NOSCRIPT 失败 | 单测 3/4 号；真集成（CLIENT PAUSE 时序竞争无法稳定构造"标记后仍 NOSCRIPT"，以 stub 为准，见 §7 边界） |
| LOAD 失败正确返回、不重试 | 单测 5 号 |
| 超时/断开不触发 LOAD | 单测 6/7 号（stub）+ **真 Redis 错误串形态实证**（CLIENT PAUSE 场景实测 `err="timeout"` 与 stub 输入一致） |
| 不重复执行已成功扣减 | NOSCRIPT 是执行前错误（Redis 脚本缓存 miss 时脚本零执行）——语义由 Redis 保证；客户端分类错误不成立 |

**真集成补充验证（本轮新增）**：CLIENT PAUSE 2500ms + 客户端 500ms 超时下，wrapper 收到 `err="timeout"` 且 **script|load 计数差 = 0**（绝不把超时当 NOSCRIPT 触发重载）——这是 stub 无法提供的真实 Redis 行为证据。

### P0-2 Redis 节点一致性 —— 通过（附验证边界）

- SCRIPT LOAD 与 EVALSHA 重试**在同一个连接 `r` 上完成**（`load_script(r, entry)` 后立即 `r:evalsha`）。
- Redis 脚本缓存是**实例级**（非连接级）：同实例任一连接 LOAD 后，连接池内其他连接的 EVALSHA 均可用（resty 池按 host:port+db 键控，本部署单实例 ⇒ 无跨节点问题）。
- **验证边界（如实声明）**：当前部署为单 Redis 实例（standalone）。**Cluster/多节点的脚本缓存按节点生效，本阶段未验证、未声称支持**（Design Deferred 已记录）。若未来 host 解析漂移到不同实例，由 NOSCRIPT 自愈路径兜底（重新 LOAD）。

### P1-3 多 Worker 与懒加载 —— 通过

- Worker 隔离：OpenResty 每 Worker 独立 Lua VM，`SCRIPTS` 模块状态天然按 Worker 独立。
- 状态竞争分析：同 Worker 并发请求同时懒加载 ⇒ 两次 `SCRIPT LOAD`（幂等，同 src ⇒ 同 SHA1）⇒ `entry.sha` 双写同值，无污染。
- 加载失败无负缓存：`entry.sha` 保持 nil ⇒ 下次调用重试 LOAD，可恢复。
- 真证据：三节点 FLUSH 后 miss 计数与请求分布一致（kong1=3/kong2=1/kong3=1，多 Worker 独立懒加载实证）；E2E 双路径（token_bucket/grant_multi）各自自愈。

### P0-4 原有限流语义 —— 通过

- 脚本文本零改动（双源 diff 为空）⇒ TOKEN_BUCKET 扣减/refill 语义、GRANT_MULTI 全或无语义不变。
- `grant()/grant_multi()` 除调用方式外一行未动；`parse_*` 防御校验未动；故障分支（503/degraded）未动。
- 回归：quota batch=1 恰 100 ✓、dims.sh 8/8 ✓、rules.sh 14/14 ✓。

## 3. 问题清单

| 级别 | 问题 | 处置 |
|---|---|---|
| P0 | 无 | — |
| P1 | 无 | — |
| P2-1 | 错误类别以字符串透传（未结构化 noscript/definite/uncertain），Phase 3 的 GRANT/RETURN 重试策略需要结构化分类 | 记录为 Phase 3 输入（届时在调用层按错误串分类包装），本期不扩大范围 |
| P2-2 | 过程违规一次：`-T` 参数补丁落地不完全时 Phase 2 干跑覆盖了 `bench/out/results-p1-w2-notice-ip.md` 工作副本 | 已在 docs/results.md 过程记录；权威数据（docs/results.md + bench/raw/phase1/）未丢失 |
| P2-3 | `test/evalsha-unit.lua` 三处用例数据错误（NOSCRIPT 误写成返回值；LOAD 失败用例误设已缓存 SHA）在首轮跑出 3 FAIL，修正后 8/8 | 已修（测试自身错误，非实现缺陷） |

## 4. 修复内容

**无 P0/P1 修复**。本轮新增一个真集成验证脚本片段（CLIENT PAUSE 超时分类，见 §2/§7），未改动生产代码。

## 5. 测试执行结果

| 测试 | 类型 | 结果 |
|---|---|---|
| `test/evalsha-unit.sh`（8 用例：懒加载/NOSCRIPT 自愈/二次 NOSCRIPT/LOAD 失败/超时不触发/断开不触发/懒加载后超时/缓存直调） | stub 单测 | **PASS 8/8** |
| SCRIPT FLUSH → batch=1 路径自愈（200 + warn 日志） | 真 Redis E2E | **PASS** |
| SCRIPT FLUSH → 多规则路径自愈（200 + warn 日志 grant_multi） | 真 Redis E2E | **PASS** |
| 多 Worker 独立懒加载（三节点 miss 计数） | 真 Redis E2E | **PASS** |
| CLIENT PAUSE 超时分类（timeout 串 + script_load delta=0） | 真 Redis 集成 | **PASS** |
| CLIENT PAUSE 时序竞争（构造"标记后仍 NOSCRIPT"） | 真 Redis 集成 | **NOT RUN**（两连接到达顺序竞争无法稳定构造；行为由 stub 4 号覆盖，记为验证边界） |
| quota.sh batch=1（100/350/0） | 真 Redis 回归 | **PASS** |
| dims.sh（8 断言） | 真 Redis 回归 | **PASS** |
| rules.sh（14 断言） | 真 Redis 回归 | **PASS** |
| GRANT_MULTI 双源 diff | 静态 | **PASS** |

## 6. 性能对比结论

同条件（k6/参数/限流配置/Worker=2/IP 直连/时长 20s，日志级别分 notice/error 两段）干净尝试行对照（@1000 RPS）：

| 场景 | 指标 | EVAL（Phase 1） | EVALSHA（Phase 2） |
|---|---|---|---|
| A batch=1 | p50/p95/p99 ms | 0.65 / 1.26 / 3.08 | 0.59 / 1.11 / 1.50 |
| A batch=1 | RedisQPS / RedisCPU / KongCPU | 4865 / 0.043s / 0.334 核 | 4732 / 0.077s / 0.268 核 |
| C 多规则 | p50/p95/p99 ms | 0.84 / 1.59 / 2.80 | 0.63 / 1.18 / 1.55 |
| C 多规则 | RedisQPS / RedisCPU / KongCPU | 3830 / 0.099s / 0.330 核 | 7814 / 0.096s / 0.300 核 |
| 传输 | GRANT_MULTI 单次 | 1982 B | 40 B（49×；200 次 387KB→8KB） |

- p99 有改善（A 3.08→1.50、C 2.80→1.55），但**量级在环境噪声与采样波动范围内**（RedisCPU 反向波动 0.043→0.077 即为例证），**不声称统计显著的延迟收益**。
- **确定的收益**：脚本传输字节 49× 下降（跨机房/公网部署时该差值会放大——微基准结果，不外推为整体性能提升 49 倍）。
- Redis QPS/CPU/Kong CPU 相当（在采样噪声内）。
- EVALSHA 次数 = 请求数 1:1、SCRIPT_LOAD = 0（稳态）、EVAL = 0 ✓。

## 7. 尚未验证的边界与遗留风险

1. **Redis Cluster/多节点**：脚本缓存按节点生效的 NOSCRIPT 行为未验证（Deferred；当前单实例声明）。
2. **"重试后仍 NOSCRIPT"的真构造**：依赖 LOAD 成功与后续 NOSCRIPT 之间的竞争，无法稳定构造（stub 4 号覆盖；真实触发路径 = FLUSH 与重试的纳秒级竞争）。
3. **错误类别结构化**（P2-1）：Phase 3 GRANT/RETURN 重试策略需要，届时处理。
4. **宿主机环境噪声**（Phase 1 发现 3）仍在（本轮 Phase 2 notice 段出现 1 次污染重跑，机制有效）。
5. **`_M.scripts` 暴露**：仅诊断/测试用途，无生产路径依赖。

## 8. 最终验收结论

**PASS**

- 无 P0/P1 问题；P2 三项均已记录（1 项转 Phase 3 输入、1 项过程记录、1 项已修）。
- 正确性证据链完整：stub 分类逻辑 8/8 + 真 Redis E2E 自愈（双路径/多 Worker）+ 真 Redis 超时分类（script_load delta=0）+ 全量回归绿。
- 性能数据真实、条件一致、无选择性筛选（RedisCPU 波动如实记录）。
- 单实例边界与 Cluster 未验证项已如实声明。
