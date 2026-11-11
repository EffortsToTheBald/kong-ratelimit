# Proposal

## Why

考题 MVP 硬要求"覆盖 Request Path / Client ID / IP 等多维控制粒度"，但 Phase 1 只实测过 `limit_by=[ip]`——多维语义是"代码支持、未证明"状态；同时 review-phase-0 的 P1 批中 5 项对外语义/可观测问题（reset 头语义误导、Retry-After 无上界、429 无日志、坏配置运行时才报 500、Redis 畸形返回无防御）直接影响交付文档的可信度。本 change 把这两类一次性闭环。

## What Changes

- **多维限流全维度验证**：新增 `bench/dims.sh` 覆盖 `[ip]`、`[ip,path]`、`[consumer,path,method]`、`[header]`、`[route]`、`[service]` 及组合——验证不同维度值独立计数、同策略稳定同 key、无意外共享桶。consumer 维度依赖认证：脚本自带 key-auth + 两个 consumer 的完整声明式配置（**不改 `kong.yml` 默认部署**，现有压测行为不受影响）。
- **`X-RateLimit-Reset` 语义修正**（**BREAKING** 响应头语义）：从"now + window 的伪窗口值"改为"**下一个令牌可用的 Unix 秒**"，与 `Retry-After` 同口径（令牌桶没有窗口重置概念，旧值对客户端无指导意义）。
- **`Retry-After` 上限**：封顶为 `window` 秒（window 内必补 ≥1 令牌），消除小 rate 场景数千秒的 Retry-After（**BREAKING**：极端配置下的响应值变化）。
- **429 可观测**：access 阶段对每个被拒请求打 info 日志（key/limit/batch），可从日志区分"确定性限流拒绝"与"Redis 故障"。
- **`header_name` 配置前置校验**（**BREAKING**：坏配置从"下发成功+运行时 500"变为"下发即 400"）：schema `entity_checks`（`conditional` + `contains`，已在 Kong 3.6 容器内核实支持并有官方用例）。
- **Redis 返回值防御校验**：EVAL 返回值必须是 3 元数组且数值合法，否则视为 Redis 异常走故障分支（默认 503 / 显式容错 degraded），不基于不可信数据放行或拒绝。
- **shared dict 降级告警**：`init_worker` 校验 `store.backend()`，降级为 worker 私有表时启动即 `log.warn`（原先静默降级）。
- **`remaining` 口径文档化**：快慢路径其实都是"本节点视角"（Phase 1 已核实），本项为文档+注释澄清，无行为变更。
- **`rule.md` §3.2/§3.3 key 格式同步**：补 `p=` 策略指纹说明（作者文档，随本 change 更新）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `rate-limiting`: 新增多维限流语义（各维度取值来源与分桶行为）、响应头语义（Reset/Retry-After）、可观测性（429 日志、降级告警）、防御性行为（畸形 Redis 返回走故障分支）、配置前置校验（header_name）的 ADDED 需求。既有 8 条需求（Phase 1 已合入主 spec）不变。

## Impact

- **代码**：`kong/plugins/rate-limit-advanced/{schema.lua, handler.lua, lib/redis.lua}`；`lib/algorithm.lua` 仅注释/传值微调
- **测试**：新增 `bench/dims.sh`（多维验证，自带 key-auth 场景配置）；既有 harness 不受影响
- **文档**：`README.md`（响应头语义）、`docs/design.md`（§7 响应头/§9 取舍）、`rule.md`（§3.2/§3.3 key 格式）
- **行为影响**：reset 头数值含义变化；`Retry-After` 极端场景变小；坏配置下发被 400 拒绝；畸形 Redis 返回从"可能 500/异常"变为确定性故障分支
- **明确不做**（留后续 change）：EVALSHA+NOSCRIPT（归 Phase 4 性能批）、Prometheus 指标（Phase 5）、本地库存回收（Phase 4）、路径归一化/基数治理（需独立设计）、多规则联合判定
