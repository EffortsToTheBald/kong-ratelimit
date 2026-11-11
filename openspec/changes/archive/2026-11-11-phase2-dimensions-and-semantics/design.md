# Design

## Context

- Phase 1（已归档）落地了策略指纹、fail-closed 默认、batch=1 短路、时间戳单调等 8 项修复；主 spec `openspec/specs/rate-limiting/spec.md` 已有 8 条需求。本 change 全部为 **ADDED** 需求，不改既有需求。
- 多维语义现状：`algorithm.lua:dim_value()` 已实现 7 个维度取值（consumer/ip/path/method/header/route/service），但从未实测——尤其 consumer 维度依赖认证插件先执行（key-auth 1250 > rate-limit-advanced 1002，优先级已按设计排好）。
- 已在 Kong 3.6 容器内核实：`entity_checks` 框架存在（`kong/db/schema/init.lua:540-720`），`conditional` 检查器 + `contains` 校验器（init.lua:332/402）可表达"数组包含 X ⇒ 另一字段必填"；官方用例见 `ip-restriction`（`config.xxx` 路径）与 `datadog`（conditional 用法、`custom_entity_check` fallback 形态）。
- 日志级别事实：`KONG_LOG_LEVEL=notice` 下 nginx **不显示 info 级**——429 判定日志必须用 `kong.log.notice`（与现有 RL-DEBUG 一致）才能被观测。
- 本地库存 fast path 的"下一令牌时间"无法本地精确计算（库存不自动补充，只能等 Redis 再授予）——reset 语义必须承认这是近似。

## Goals / Non-Goals

**Goals:**

- 把"多维支持"从代码事实变成可验证行为（7 维度 + 组合，全部有自动化断言）。
- 5 项 P1 语义/可观测问题闭环：reset 语义、Retry-After 上限、429 日志、header_name 前置校验、Redis 防御校验；外加 shared dict 降级告警（P1-8）与 remaining 口径文档化（P1-3）。
- 不破坏既有压测：`kong.yml` 默认部署、bench harness 行为不变。

**Non-Goals:**

- EVALSHA+NOSCRIPT：性能优化，归 Phase 4（本 change 不动 redis.lua 的调用方式）。
- Prometheus 指标（Phase 5）、本地库存回收协议（Phase 4，需滞留数据做设计输入）。
- 路径归一化/维度基数治理：改变桶身份语义，需独立设计。
- 多规则联合判定（单请求多桶）：明确不支持（review §5）。

## Decisions

### D1. `X-RateLimit-Reset` = 下一个令牌可用的 Unix 秒

- **slow path（Redis）**：脚本把 wait 公式统一为 `wait = max(0, (1 - tokens) / rate)`（tokens≥1 时为 0 = "下一令牌已可用"），handler 以 `reset = now + wait` 计算。现脚本只在 tokens<1 时算 wait，改为恒算（纯公式统一，无额外 RTT）。
- **fast path（本地库存）**：`remaining > 0` → `reset = now`（本地视角下一令牌已可用）；`remaining == 0`（刚取走最后一个）→ `reset = now + ⌈1/rate⌉`（近似：等待一个补充周期；本地无法精确知道 Redis 何时再授予，取保守值并在文档写明"本节点视角"）。
- 保留 Unix 秒格式（与 Kong 官方插件一致，客户端解析习惯不变）；改"剩余秒数"格式是第二种候选，被否（破坏兼容）。
- "桶回满时间"方案被否：burst 远大于剩余时数值巨大（如 99.5/0.028≈3600s），对客户端无 retry 价值。
- 备选"按 remaining 展示全局剩余"被否（需要额外 RTT，review 已记录）。

### D2. `Retry-After` 上限 = window

- handler 侧 `retry_after = min(max(1, ceil(wait)), floor(window))`。
- 依据：`rate = limit/window` ⇒ 一个 window 内必补 ≥1 令牌，等待超过 window 的 Retry-After 没有意义。
- 极端配置（limit=1/window=3600）的 Retry-After 从 3600 保持 3600；更小 rate 不可能（rate 下界 1/window）。配合 D1，429 响应中 `Reset − now ≈ Retry-After`。

### D3. Redis 返回值防御校验 → 故障分支

- `redis.lua:grant()` 在解析 EVAL 结果前校验：`type(res) == "table"`、`#res == 3`、`granted = tonumber(res[1])` 非 nil 且 `0 ≤ granted ≤ want`、`tokens/wait` 可 tonumber。任一失败 → `r:close()` + `return nil, "malformed eval response"`。
- 校验逻辑抽为纯函数 `parse_grant_response(res, want)`（不依赖 cosocket），畸形数据的测试用 resty 单测直接喂样例（E2E 无法注入畸形返回，如实记录）。
- **选故障分支而非 review 原建议的"视为拒绝(429)"**：429 是确定性算法产出，不应由数据异常触发；畸形返回说明 Redis 状态不可信，走 fail-closed(503)/degraded 分支让策略显式化。run_with_invalid 语义与 fail-closed 默认一致。

### D4. `header_name` 前置校验：entity_checks（conditional + contains）

```lua
entity_checks = {
  { conditional = {
      if_field = "config.limit_by",
      if_match = { contains = "header" },
      then_field = "config.header_name",
      then_match = { required = true },
  } },
}
```

- 已核实三要素齐全：`entity_checks` 数组机制（init.lua:540-575 文档）、`conditional` 检查器（init.lua:694-720）、`contains` 校验器（init.lua:332，注册于 402）；官方插件用例：`ip-restriction`（顶层 `config.xxx` 路径）、`datadog`（conditional 形态）。
- Fallback（若 contains 对数组不生效）：`custom_entity_check` + `field_sources`（datadog:141-145 形态）。再 fallback：保留运行时 500——此时 spec 的"下发即 400"场景需回退修订，**实施首日必须先实测此项**。
- 运行时兜底校验（build_key 内）保留：双保险防绕过 schema 校验的路径（如 vault 引用）。

### D5. shared dict 降级告警：`init_worker`

- `handler.lua` 增加 `function _M:init_worker()`：`store.backend()` 非 `shared_dict` 时 `kong.log.warn("rate-limit-advanced: lua_shared_dict kong_rl 不可用，本地库存降级为 worker 私有表（精度下降）")`。
- init_worker 无 conf 参数（Kong 全局 phase），但 `backend()` 不需要 conf。
- 降级行为本身不变（worker 表降级运行），只补可观测性。

### D6. consumer 维度验证方案：dims.sh 自带认证配置

- 不改 `kong.yml`（避免全站强制认证破坏既有压测）。`bench/dims.sh` 的 consumer 场景自行下发完整声明式配置：
  - 服务 echo + 两条路由：`/echo`（无认证，行为不变）、`/echo-auth`（挂 key-auth）；
  - consumers：`alice`、`bob` 各持一个 keyauth credential；
  - rate-limit-advanced 挂在 `/echo-auth` 路由，`limit_by=[consumer]`。
- 优先级顺序（key-auth 1250 先于 1002）由该场景实测确认。
- 其余 6 个维度场景挂在 `/echo`（无认证），每场景独立 namespace + FLUSHDB。

### D7. `bench/dims.sh` 结构（自动化多维验证）

- 复用 `xff.sh` 的模式：`mk_json` 构造配置、`apply_config`、计数断言、PASS/FAIL 明确。
- 场景：①`[ip,path]` 两路径独立；②`[method]` GET/POST 分桶；③`[header]` 双租户 + 缺失哨兵；④`[route]` key 含 route.id；⑤`[service]` key 含 service.id；⑥`[consumer]`（key-auth 双 consumer + anon）；⑦维度顺序指纹不同（调 `policy_fingerprint` 纯函数断言）。
- 每场景输出 PASS/FAIL，任一 FAIL 脚本 exit 1。

### D8. 429 日志与 remaining 口径

- 429 分支：`kong.log.notice("rate-limit-advanced: 429 key=", key, " limit=", conf.limit, " batch=", batch)`（notice 级才能在 KONG_LOG_LEVEL=notice 下可见）。
- `remaining` 口径：代码注释 + README/design 写明"两路径均为本节点视角"（Phase 1 已核实慢路径 granted−1 即 fill 后本地库存），无行为变更。

### D9. rule.md key 格式同步

- §3.2/§3.3/§3.4 的示例与说明补 `p=<8位hex>` 指纹：格式、输入（limit/window/解析后 burst/limit_by/header_name）、"策略变更即新桶"代价与 namespace 逃生门。作者文档，经确认纳入本 change。

## Risks / Trade-offs

- [conditional+contains 对数组不生效] → 实施首日实测下发；fallback `custom_entity_check`；再不行回退运行时 500 并修订 spec 场景（风险链已标注，不影响其他任务）。
- [reset=now 被客户端误读为"窗口已重置"] → 语义是"下一令牌已可用"；README/design 明确写口径与令牌桶模型，不伪装成固定窗口。
- [fast path reset 的 ⌈1/rate⌉ 近似] → 本地无法精确知道 Redis 再授予时机，取保守值；文档承认本节点视角。
- [429 日志在高拒绝率下放大日志量] → notice 级单行日志，量级与现有 RL-DEBUG 相当；Phase 5 结构化日志时统一治理。
- [dims.sh 下发的 key-auth 配置残留] → 后续任何 quota.sh/matrix.sh 运行会用其自建配置整体覆盖，无持久影响；dims.sh 末尾不主动清理（保持与其他脚本一致的行为）。
- [防御校验把极端合法返回误判] → 校验面只覆盖 EVAL 返回结构（3 元数组、数值范围），不涉业务语义；`granted ≤ want` 由脚本保证，收紧为防御断言。

## Migration Plan

1. 基线 commit（延续组级 commit 约定）。
2. 代码修改（D1-D5、D8），逐项自测：resty 纯函数单测（parse_grant_response、指纹顺序）+ 容器内实测（reset/cap/429 日志/400 下发/降级告警）。
3. `bench/dims.sh` 编写与全场景执行（7 场景全绿）。
4. 文档同步（README、design.md、rule.md）。
5. 集成验收：全 case 复跑 + Phase 1 的 batch=1 基线回归（确认无回归）→ `reports/phase-2-dimensions-and-semantics.md`（§13 格式）。
6. 回滚：组级 commit revert 即可；响应头语义变化无持久化影响。

## Open Questions

（无阻塞项。entity_checks 的实测结果决定 D4 的主方案/fallback 选择，属实施首日事实核查，已在任务中前置。）
