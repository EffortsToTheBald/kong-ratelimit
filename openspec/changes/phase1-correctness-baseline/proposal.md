# Proposal

## Why

Phase 0 审查（`docs/review-phase-0.md`，2026-11-11）证实：令牌桶算法与 Redis Lua 原子扣减本身是正确的，但存在 6 个 P0 级缺陷使项目无法满足 `rule.md` §14 的验收标准——最严重的是"配置变更后旧 Redis 桶与旧本地库存被新策略继承"（实测 allowed=116 > limit=100 的真实超发）与"默认 fail-open 违背既定的 fail-closed 策略"。`rule.md` 的分阶段计划要求正确性优先于一切性能优化，Phase 1（核心正确性基线）必须先行。本 change 就是这个基线。

## What Changes

- **策略指纹进 Key**（P0-1，**BREAKING** key 格式）：限流 key 从 `kong:rl:{rl:ip=…:path=…}` 变为 `kong:rl:{rl:p=<8位hash>:ip=…:path=…}`，hash = FNV-1a(limit, window, burst(解析后), limit_by, header_name)。策略一变即得新桶，旧桶与旧本地库存按既有 TTL 自然淘汰；消除跨轮次/跨配置的状态继承。
- **默认 Fail-Closed**（P0-2，**BREAKING** 默认行为）：`schema.lua` 的 `fault_tolerant` 默认 true→false，`kong/kong.yml` 同步为 false；`fault_tolerant: true` 保留为显式选择的"放行 + `X-RateLimit-Status: degraded`"模式。
- **Redis 失败路径修复**：移除 `algorithm.lua` 中"先解引用 `granted.granted` 再判 nil"的调试日志（`rule.md` §9.1 问题 A）。现状下 Redis 失败会抛 Lua 异常返回 500，且永远走不到 `fault_tolerant` 分支；修复后失败按设计返回 nil，进入 fail-closed(503) / fail-open(degraded) 分支。
- **时间回拨不重复计费**（P0-4）：Redis Lua 脚本中 `ts` 单调不回退（只在 `now > ts` 时推进并回写）。内嵌脚本（`lib/redis.lua`）与独立脚本（`redis/token_bucket.lua`）同步修改。
- **batch=1 严格短路**：`batch=1` 时完全跳过本地库存（`store.take`/`store.fill` 均不走），每请求必经一次 Redis EVAL，恢复"batch=1 = 严格全局一致"的基线定义（review P1-6，纳入本基线）。
- **IP 维度信任模型显式化**（P0-3，定性修正）：Kong 默认 trust none（`trusted_ips` 未配置时 nginx realip 不改写 `remote_addr`），当前部署下伪造 `X-Forwarded-For` 并**不能**绕过 IP 限流——review 原判断过重。本项改为：① 修正 `algorithm.lua` 中不存在的 PDK 调用 `kong.client.get_remote_ip`（PDK 只有 `get_ip()`，当前是潜在 nil 调用）；② 文档写明 IP 取值语义（`get_forwarded_ip()` = realip 处理后的 `remote_addr`，仅在 `trusted_ips` 配置下采信转发头）；③ 新增"伪造 XFF 不产生新桶"的回归测试钉死默认部署行为。
- **压测脚本收敛**（P0-6 + P0-5 收尾）：`bench/common.sh` 的配置生成器参数化 namespace（每轮独立，杜绝跨轮污染）并显式对齐 fail-closed；`bench/quota.sh` 增加每节点请求数断言（必须严格等于 PER_NODE，不满足即测试失败）。
- **回滚基线**：任何修改前先提交 git 基线 commit（`rule.md` 15.1-10"每阶段保留可回滚版本"，当前仓库零提交）。

## Capabilities

### New Capabilities

- `rate-limiting`: 多 Kong 节点共享全局令牌桶配额的核心行为——桶的策略身份（key 指纹）、batch=1 严格模式与 batch=N 租赁模式的配额边界、令牌补充与 Redis 时间处理、Redis 故障时的默认 fail-closed、IP 维度取值的信任语义。

### Modified Capabilities

（无——`openspec/specs/` 目前为空，这是项目第一份 capability spec。）

## Impact

- **代码**：`kong/plugins/rate-limit-advanced/{schema.lua, lib/algorithm.lua, lib/redis.lua}`；`redis/token_bucket.lua`（与内嵌脚本双源同步，双源问题 P2-3 记录在案、本阶段不合并）
- **配置**：`kong/kong.yml`（`fault_tolerant: false`）；`docker-compose.yml` 不变
- **测试**：`k6/quota.js`（配合每节点断言）、`bench/{common.sh, quota.sh}`、新增伪造 XFF 场景；产出 `reports/phase-1-correctness.md`（`rule.md` §13 十二节格式，未执行的测试必须标 NOT RUN）
- **文档**：`README.md`（§7 验收清单 degraded 行、§5 batch 表）、`docs/design.md`（§4.6/§7 故障模式、§9 取舍表、§12 key 设计）
- **运行时影响**：Redis key 格式变化（旧 key 按 2×window TTL 自然过期，无需迁移）；Redis 故障响应从 500 变为 503（fail-closed 默认）；默认故障行为从"放行"变为"拒绝"
- **明确不做**（留给后续 change）：P1 语义类（reset/remaining 口径统一、EVALSHA、Retry-After 上限、响应头统一）、batch 性能矩阵与库存回收（Phase 4）、Prometheus 指标（Phase 5）、多规则联合判定、路径归一化
