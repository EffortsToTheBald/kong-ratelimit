# Design

## Context

现状与约束（动机见 proposal.md 的 Why）：

- 代码骨架已定型：`handler.lua`（access 判定/响应）→ `algorithm.lua`（key/决策）→ `store.lua`（本地库存）+ `redis.lua`（连接与内嵌令牌桶 Lua）。`rule.md` 15.1 明确禁止重写架构，本设计全部为**最小修改**。
- `docs/review-phase-0.md` 给出 P0×6 分级清单；本设计逐项落实，并按实测证据修正其中两项的定性（P0-3 XFF 可利用性、P0-5 已在仓库侧修复，仅剩断言收尾）。
- PDK 事实（已核实 Kong 官方源码/文档）：`kong.client.get_forwarded_ip()` 返回 realip 处理后的 `ngx.var.remote_addr`；是否采信转发头由 `trusted_ips`/`real_ip_header`/`real_ip_recursive` 决定，默认 `trusted_ips = none` ⇒ 不采信。PDK **不存在** `get_remote_ip` 函数（`algorithm.lua:22` 的当前写法是潜在 nil 调用）。
- 验证环境：3× Kong 3.6 DB-less（每节点 2 worker）+ Redis 7（docker compose）；无前置 LB，端口固定（8030/8010/8020）；每轮测试须 `restart kong + FLUSHDB + 独立 namespace`（rule.md §12.1）。
- git 仓库当前零提交，任何修改前必须先打基线（rule.md 15.1-10）。

## Goals / Non-Goals

**Goals:**

- 六项 P0 缺陷全部闭环，外加两项基线配套（nil 解引用、batch=1 短路），使 rule.md §14 中"正确性"相关验收行全部可证明。
- 每个 P0 修复都附带可执行的测试或回归场景，产出 `reports/phase-1-correctness.md`。
- 修改量最小化：不动模块边界、不动响应头结构、不动 TTL 算法。

**Non-Goals:**

- P1 语义统一（reset/remaining 口径、EVALSHA、Retry-After 上限、429 日志结构化）——留给后续 change。
- batch 性能矩阵、库存回收、自适应 batch（Phase 4）。
- Prometheus 指标与结构化日志（Phase 5）。
- 多规则联合判定、路径归一化、Redis Cluster/Sentinel 部署形态（当前单实例 Redis，hash tag 语义仅为前向兼容）。

## Decisions

### D1. 策略指纹：输入、算法与 key 布局（对应 P0-1）

- **输入**：`limit`、`window`、`burst`（**解析后**的值，`burst=0` 视作 `limit`，保证语义等价的配置得到同一个桶）、`limit_by`（按配置数组顺序 join）、`header_name`（仅当 `limit_by` 含 `header` 时参与）。**不含 `batch`**。
- **算法**：FNV-1a 32-bit，输出 8 位小写 hex。纯 Lua 约 10 行，无新依赖（rule.md 15.1-5）。备选的"完整参数串直接编码进 key"被否：key 过长且无必要；"版本号计数器"被否：需要跨节点共享的递增状态，引入新的一致性问题。
- **布局**：`kong:rl:{rl:p=<hex8>:ip=…:path=…}`。`p=` 元素放在 hash tag 内部、namespace 之后，保持 `rule.md` §3.2"完整规则标识必须放入 hash tag"的约束不变。
- **为什么不含 batch**：batch 是"运输参数"（一次领多少），不改变桶的身份；把它算进指纹会让调 batch 重置整个桶（无意义地清空全局配额）。旧库存与 batch 的兼容问题由 batch=1 短路（D4）+ 指纹共同覆盖。
- **代价（须写进文档）**：策略变更 ⇒ 新桶满血复活。运维如需"改 limit 但继承旧余量"，用 `namespace` 显式控制——这是 rule.md §3.4 预留的机制。

### D2. Fail-Closed 默认（对应 P0-2）

- `schema.lua`：`fault_tolerant` 默认 `true → false`；`kong/kong.yml` 同步显式 `false`；README §7 验收清单与 `docs/design.md` §9 取舍表同步改写（原文把 fail-open 写成默认取舍）。
- `fault_tolerant=true` 行为完全保留（放行 + `X-RateLimit-Status: degraded`），仅从"默认"降级为"显式选择"。
- 备选"用环境变量控制默认值"被否：增加配置面，且 rule.md 已明确策略方向。

### D3. Redis 失败路径修复（对应 rule.md §9.1 问题 A）

- `algorithm.lua:check()`：把 `redis_mod.grant` 的 nil 判定**前移**到任何 `granted.granted` 解引用之前；失败走 `kong.log.err` + `return nil, err`。RL-DEBUG 调试日志保留但移到成功路径之后。
- 备选"pcall 包裹整个 check"被否：会把真正的逻辑 bug 也吞成 fail-open，掩盖问题。

### D4. batch=1 短路本地库存（review P1-6 提级）

- `check()` 先 `resolve_batch`：`batch == 1` 时跳过 `store.take`/`store.fill`，每请求必经一次 EVAL。
- 理由：恢复"batch=1 = 严格全局一致"的基线定义（否则残留库存可被"接走"，spec 的"本地库存命中次数为 0"无法证明）；同时消除 batch=1 下的 60s 墓碑 key 副作用。
- 备选"依赖 D1 指纹自然保证"被否：指纹只在配置变更时隔离，同配置轮次内不解决语义纯度问题。

### D5. 时间戳单调（对应 P0-4）

- Lua 修改（`lib/redis.lua` 内嵌脚本 + `redis/token_bucket.lua` 双源同步，P2-3 双源问题本阶段不合并）：
  - 补充与 `ts` 推进都收进 `if now > ts` 分支：`tokens = min(burst, tokens + (now-ts)*rate)`；`ts = now`；
  - `HSET` 回写 `ts` 时写**分支内的 ts 值**而非裸 `now`，保证时钟回拨期间 `ts` 不被覆盖。
- 回拨期间桶不补充 ⇒ 少发，误差方向与整体不变量一致（只少发不超发）。
- 无服务端告警（Lua 内无法记 Kong 日志），在 `reports/phase-1-correctness.md` 记录该限制。

### D6. IP 维度信任模型显式化（对应 P0-3，定性修正）

- **结论修正**：默认部署（`trusted_ips=none`）下 realip 不改写 `remote_addr`，伪造 XFF **不能**绕过 IP 限流；review 原判断"可被轻易绕过"过重。真正的问题是**语义未被钉死、且有一处失效回退**。
- 修改三点：
  1. `algorithm.lua:22` 回退调用改为 PDK 真实存在的 `kong.client.get_ip()`（直连对端，永不可伪造），消除潜在 nil 调用；
  2. 文档写明语义：`get_forwarded_ip()` = realip 解析结果，仅在 `trusted_ips` 配置后采信上游转发头——与 Kong 官方 rate-limiting 插件的 IP 判定口径一致；
  3. 回归测试钉死默认行为：同源 IP 携带不同伪造 XFF 必须命中同一桶（spec 场景"伪造 XFF 不产生新桶"）。
- 备选"一律用 `get_ip()`"被否：会破坏 `trusted_ips` 已配置的 LB 部署（所有流量记到 LB IP）；备选"新增 `ip_source` 配置项"被否：超出本阶段最小修改原则，P2 记录。

### D7. 压测脚本收敛（对应 P0-6 + P0-5 收尾）

- `bench/common.sh`：`kong_config_json` 增加 namespace 参数（第 5 参），`quota.sh`/`matrix.sh` 每轮生成独立 namespace（如 `rl-$(date +%s)`），杜绝跨轮次共享桶；生成配置中显式 `fault_tolerant:false`。
- `bench/quota.sh`：解析 k6 summary 的 `requests_kong1/2/3` 计数，**严格等于 PER_NODE 否则脚本失败**——把 P0-5 的"每节点请求数可控"从脚本结构保证升级为运行时断言。
- 前置事实：仓库 `k6/quota.js` 已是 `per-vu-iterations` + VU 绑定节点（`(__VU-1)%3`）+ ITER 整除校验，结构上已满足固定分配，无需再改。

### D8. 回滚基线（rule.md 15.1-10）

- 动手前 `git add -A && git commit` 打基线（当前零提交）；同时补 `.gitignore`（`bench/out/`、`reports/` 产物按需）避免把测试产物提交进基线。验收通过后再提交修复 commit，形成可 diff/可回滚的两个锚点。

## Risks / Trade-offs

- [策略变更即满血新桶（配额"重置"）] → 写入 README/design 文档；`namespace` 是显式逃生门；误差方向仍是"多放"而非"超发上限失控"（受 limit 本身封顶）。
- [32-bit 指纹碰撞] → 单项目规则规模下概率可忽略；如出现按位冲突再扩展为 64-bit（布局不变，仅 hex 长度变化）。
- [默认 fail-closed 使可用性下降] → 这是 rule.md 既定策略取舍；`fault_tolerant=true` 显式保留；文档同步。
- [时钟回拨期间不补充导致少发] → 与"只少发不超发"的全局误差方向一致；报告中记录"无服务端回拨告警"的限制。
- [batch=1 下 `X-RateLimit-Remaining` 恒为 0] → 既有语义（慢路径本就返回 granted−1），本阶段不改；P1-3 统一口径时处理。
- [quota.sh 每节点断言依赖 k6 VU 编号顺序] → `per-vu-iterations` 保证 VU 编号 1..VUS 顺序启动；若断言失败恰好暴露假设失效，属期望行为（fail loudly）。
- [新旧 key 在升级瞬间并存] → DB-less 三节点逐一下发配置，存在秒级窗口；测试规程要求先全部下发再开压（rule.md §12.1 重启+FLUSHDB 已隔离）；旧 key 随 TTL ≤ 2×window 消失。
- [本机环境特殊（WSL mirrored 网络、端口 8030/6380、代理拉镜像）] → 已记录于 review 附录；报告需包含环境说明，否则无法复现。

## Migration Plan

1. 打基线 commit（D8）。
2. 代码与配置修改（D1–D7），逐项自测。
3. `docker compose restart kong1 kong2 kong3` → 等 Kong 就绪 → `FLUSHDB` → 三节点下发新配置 → 依次执行 rule.md Phase 1 测试 A/B/C/D 与新增回归场景。
4. 产出 `reports/phase-1-correctness.md`（rule.md §13 十二节格式；未执行的测试标 NOT RUN，禁止编造）。
5. 回滚策略：`git revert` 至基线 commit 即回到现状；新格式 key 无持久化迁移问题（Redis 无 AOF/RDB，`--save ""`），旧格式 key 随 TTL 自然消失。

## Open Questions

（无阻塞项。指纹 hex 长度、墓碑 TTL 等实现细节在编码时确定，不影响 spec 与任务拆分。）
