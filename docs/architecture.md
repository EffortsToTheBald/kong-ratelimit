# 架构：rate-limit-advanced（V1，Phase 0–8.2 冻结版 + 关口二/三/四整改）

> 配套：`docs/design.md`（设计文档与误差分层推导）、`docs/REMEDIATION.md`（整改关口冻结记录）、
> `docs/reports/PHASE7_PERFORMANCE_REPORT.md`（性能）、历史报告见 `docs/reports/` 与 `docs/PHASE*_*.md`。
> 术语约定：**Lease** = Worker 本地预授权库存；**GRANT_LEASE / GRANT_MULTI** = Redis Lua 脚本；
> **CLOSED** = 本地耗尽态；**EXPIRED** = 过期摘除（**唯一产生 discarded 的状态**：未消费库存计入
> discarded，不归还 Redis）；**EVICTED** = Pool 回收事件（整池删除，仅限无 ACTIVE Lease 的空池，
> 零库存损失，**不是 Lease 状态**）；
> **outstanding** = Worker 本地尚未消费的库存；**discarded** = 过期/淘汰丢弃的未消费库存（不归还 Redis）；
> **lost** = 已授权但无法继续使用的库存（Worker 崩溃等）；**uncertain** = Redis 可能已扣但 Worker 未登记（不重试不登记）。

## 1. 整体架构

```
                      ┌───────────────────────────────────────────┐
 Client ─────────────▶│ Kong 副本 ×3（DB-less，每副本 2 Worker）    │
                      │                                           │
                      │  Kong#1            Kong#2       Kong#3    │
                      │  ┌──────────┐     ┌──────────┐ ┌──────────┐│
                      │  │WorkerA   │     │WorkerA   │ │WorkerA   ││
                      │  │ _pools   │     │ _pools   │ │ _pools   ││  ← Lease 池为
                      │  │WorkerB   │     │WorkerB   │ │WorkerB   ││    Worker 私有
                      │  │ _pools   │     │ _pools   │ │ _pools   ││    （Lua VM 隔离）
                      │  └──────────┘     └──────────┘ └──────────┘│
                      │        access 阶段：rate-limit-advanced     │
                      └───────────────┬───────────────────────────┘
                                      │ 三条请求路径（见 §2）
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
  batch=1（每请求）            单规则 batch>1                  多 rules（每请求）
  EVALSHA token_bucket        Worker 私有 Lease TAKE          EVALSHA GRANT_MULTI
        │                     （不足→GRANT_LEASE）                  │
        └──────────────┬──────────────────────┴───────────────┬─────┘
                       ▼                                      │
              ┌──────────────────┐        Redis 故障（超时/断连）│
              │    Redis 7（单实例）│◀──────── Fail-close 503 ──┘
              │ 全局令牌桶（唯一权威）│        （fault_tolerant=true ⇒
              │ Lease 元数据（1h TTL）│          显式降级放行）
              └──────────────────┘
```

- **Worker 隔离**：每个 Worker 拥有独立的本地 Lease Pool（Lua VM 按 Worker 隔离，`lease.lua` 的
  `_pools`/`_counters` 为 Worker 私有）；Lease 只归属于创建它的 Worker；**不存在跨 Worker 共享同一份
  本地库存**；Worker 之间通过 Redis 共享全局配额状态（唯一权威）。
- **不依赖 Shared Dict**：Legacy shared-dict 聚合库存已随 Phase 8.2-A 移除。
- **核心不变量**：全局配额唯一权威在 Redis；本地库存只能来自 Redis 已授权的 Lease。
  在 Redis 授权状态连续有效（无主从切换回滚、无数据重置）且统计口径一致的前提下，
  **累计放行量 ≤ Redis 已确认扣减的授权量**（推导，前提化表述，docs/design.md §4.2）；
  少发多来源（Worker 崩溃 lost、GRANT 不确定、过期/淘汰 discarded），超发仅可能出现在
  故障回滚窗口；Worker 崩溃的未消费库存走损失方向（`granted = consumed + lost`）。

## 2. 三种限流路径

| 模式 | 授权方式 | Redis 操作 | 本地库存 |
|---|---|---|---|
| `batch=1` | 逐请求授权 | 每请求执行 Lua（token_bucket） | 无 |
| 单规则 `batch>1` | Lease 预授权 | 库存不足时申请（实测约每 batch 个请求 1 次） | 有（Worker 私有） |
| 多规则（`rules`） | 多键原子授权 | 每请求执行 GRANT_MULTI | 无 |

batch>1 另有两条**降级直连**路径（关口二/三冻结，均复用 batch=1 既有语义、不登记本地库存、
不进 Lease 账目）：

| 触发 | 行为 |
|---|---|
| MAX_POOLS（10000/Worker）满且无可淘汰空池 | 该请求 batch=1 直连授权；**不 429、不 503**（攻击性高基数 key 无法据此拒绝正常用户）；日志 `pool_cap_degraded` |
| 该 Pool 已有在途 GRANT（方案 B：单 Pool 单在途） | 并发请求 batch=1 直连授权；日志 `inflight_degraded` |

实现位置：`lib/algorithm.lua` 的 `check()`（batch 解析分流）、`check_lease()`（Lease 路径 +
降级判定）、`check_multi()`（多规则路径）。

- **batch=1**：每请求一次 EVALSHA token_bucket；`X-RateLimit-Remaining` 恒为 0（授予的 1 个令牌被
  当前请求立即消耗）。Phase 6.4/7 实证：EVALSHA 数恰=请求数、Redis 侧 Lease 记录为 0。
- **单规则 batch>1**：预授权模式——配额以 batch 粒度预扣，本地消费零网络 I/O；**不提供与 batch=1
  相同的逐请求时序精度**，本地消费可能形成短时突发。`X-RateLimit-Remaining` = 本地池余量
  （fast path）或 granted−1（slow path）。
- **多规则**：α 强一致——每请求一次 GRANT_MULTI（组内同 hash tag ⇒ 同 slot，单脚本全检-全扣/全不扣）；
  响应为瓶颈规则口径；429 体含 `rule` 字段。多规则不使用 Lease。

## 3. 单请求决策流程（与当前代码一致）

```mermaid
flowchart TD
    REQ["请求进入限流"] --> KEY["构造限流键<br/>维度取值 + 策略指纹 p="]
    KEY --> MODE{"配置形态"}
    MODE -->|"rules 多规则"| MGRANT["GRANT_MULTI<br/>全部桶 ≥1 ⇒ 各扣 1 放行<br/>任一不足 ⇒ 全部不扣 ⇒ 429(rule)"]
    MGRANT -->|"不可用/不确定"| FT
    MODE -->|"单规则 batch=1"| B1["EVALSHA token_bucket<br/>granted=1 消费 1"]
    B1 -->|"> 0"| PASS
    B1 -->|"granted=0"| REJ
    B1 -->|"故障/不确定"| FT
    MODE -->|"单规则 batch>1"| TAKE{"本地 Lease TAKE<br/>（非 yield 原子片段）"}
    TAKE -->|"命中"| PASS["放行 200<br/>Remaining=本地池余量"]
    TAKE -->|"NEED_GRANT"| DEGQ{"降级判定<br/>（非 yield）"}
    DEGQ -->|"MAX_POOLS 满且无可淘汰池<br/>或该 Pool 在途 GRANT"| DIRECT["batch=1 直连授权<br/>（不登记本地库存<br/>不进 Lease 账目）"]
    DIRECT -->|"> 0"| PASS
    DIRECT -->|"granted=0"| REJ
    DIRECT -->|"故障/不确定"| FT
    DEGQ -->|"正常"| G["GRANT_LEASE<br/>原子：参数校验→refill→部分授予→扣桶→建记录"]
    G -->|"granted≥1"| USE["登记 Lease + TAKE 消费 1<br/>（同段非 yield 片段）"]
    USE --> PASS
    G -->|"granted=0（桶令牌<1）"| REJ["429 · Retry-After<br/>（不建 Lease）"]
    G -->|"explicit_error<br/>（确定零写入或已写入不可回滚）"| FT
    G -->|"uncertain（超时/断连/畸形）"| FT["故障分支：Fail-close 503 或降级<br/>不重试 · 不登记本地库存"]
    FT -->|"fault_tolerant=false（默认）"| S503["503"]
    FT -->|"fault_tolerant=true"| DEG["放行 · X-RateLimit-Status: degraded"]

    REJ(["429 + Retry-After（封顶 window）"])
    PASS --> UP["上游服务"]
```

要点：**Redis 异常（含不确定结果）不会映射为 429**；granted=0 才是确定性限流拒绝。

## 4. Token Bucket 模型

- `rate = limit / window`（每秒补充速率）；桶容量 `capacity = burst > 0 ? burst : limit`
- refill 公式：`tokens = min(capacity, old_tokens + rate × elapsed)`；补充时间戳**只前进不后退**
  （时钟回拨期间不补充、不覆盖 ts——防同一段时间二次计费）
- 部分授予：`granted = min(batch, floor(tokens))`；`tokens < 1 ⇒ granted=0`（确定性不足，不建 Lease）
- 状态存储：Redis Hash（`tokens`/`ts`）+ `PEXPIRE`（桶 TTL = 2×window）

## 5. Redis Key 设计

```
<kong:rl>:{<namespace>:p=<策略指纹>:<维度>=<值>...}     # 桶键（单规则）/ 多规则组内各规则桶
<桶键>:lease:<lease_id>                                 # Lease 元数据记录（与桶键同 hash tag ⇒ 同 slot）
```

- **维度值编码**（关口四任务 A）：`<值>` 中的 `:` `{` `}` `%` 经
  `lib/keys.lua encode_value` 转义为 `%3A` `%7B` `%7D` `%25`（其余字节原样），
  多维组合不碰撞、同输入 key 稳定、维度值不可能破坏 hash tag 结构；
  Lease 键 = 桶键后追加 `:lease:<lease_id>`，与桶键同 slot（消除 CROSSSLOT；
  旧格式 `<kong:rl>:lease:<lease_id>` 已废弃，旧记录随 1h TTL 自然消失）。

- **策略指纹**（FNV-1a 32 位）输入：`limit / window / burst（≤0 归一化为 limit）/ limit_by 顺序 /
  header_name（仅含 header 维度时参与）`；**batch 不参与**（运输参数，调 batch 不清空桶）
- **配置变化 ⇒ 新指纹 ⇒ 新 Pool Key**：新配置不复用旧库存；旧桶/旧 Lease 记录随 TTL 自然消亡；
  **旧 Pool 生命周期回收尚未实现（Deferred）**
- 多规则组键：组指纹 = 全部规则参数的指纹（`g=` 前缀语义），组内各桶同 hash tag ⇒ 同 slot
- `key_prefix` 可配置（默认 `kong:rl`）

## 6. Redis Lua 原子操作（Phase 2–3 冻结协议）

| 脚本 | 用途 | 要点 |
|---|---|---|
| token_bucket | batch=1 逐请求授权 | refill + 扣 1 + TTL，TIME 单调 |
| GRANT_MULTI | 多规则原子多键 | 全检-全扣/全不扣；组内同 slot 单脚本 |
| GRANT_LEASE | batch>1 预授权 | 单脚本原子：参数校验→refill→部分授予→扣桶→建 Lease 记录（OPEN）→PEXPIRE |
| RETURN_LEASE | 幂等归还 | **已实现但 V1 不接线**（Phase 5 Deferred，请求路径不调用） |

脚本双源：`lib/redis.lua` 内嵌文本与 `redis/*.lua` 独立文件 diff 校验一致。

## 7. Lease 生命周期与本地 Pool（V1 冻结 + 关口二/三整改）

```text
本地无可用 Lease（NEED_GRANT）
        │
        ├── 降级判定（非 yield）：MAX_POOLS 满且无可淘汰池 / 该 Pool 在途 GRANT
        │        └──> batch=1 直连授权（不登记本地库存，不进 Lease 账目）
        │
        v
Redis GRANT_LEASE
        ├── granted=0 ──────> 配额不足 ⇒ 429（确定性，不建 Lease）
        ├── Redis 异常 ──────> 故障分支（Fail-close 503 / 显式降级）
        ├── 结果不确定 ──────> Fail-close；不重试、不写入本地库存（uncertain 单列）
        │                     （Redis 可能已扣桶并建记录 ⇒ 库存损失方向，不补偿）
        └── 授权成功（granted≥1）
                │
                v
          Worker 本地 Lease（ACTIVE，登记于创建 Worker 的 _pools；
          每 Pool active Lease 数上界 = 1 ⇒ TAKE 最坏扫描 O(1)）
                │
                v
             TAKE（每次消费 1，非 yield 原子；TAKE 时惰性判定过期）
                │
        ┌───────┼──────────┐
        │       │          │
        v       v          v
      消费中   耗尽      created_at + max_age/1000 < now
        │       │          │
        │       v          v
        │    CLOSED      EXPIRED：从 active 摘除，未消费库存计入
        │    （摘除，      discarded（一次计数，不归还 Redis）
        │    保留诊断）
        │       └── 后续请求触发新的 GRANT_LEASE
        │
        └── Pool 级：active 空且空闲超 max_age ⇒ Timer 回收整池；
            MAX_POOLS 压力下只淘汰无 ACTIVE Lease 的空池（EVICTED，零库存损失）；
            60s 低频 Timer 兜底（每轮处理数有上限、跳过在途 GRANT、回调异常隔离）
```

- **状态机**：本地 Lease 状态 ACTIVE→CLOSED / EXPIRED（EXPIRED 摘除时未消费库存计入
  discarded，一次计数，不归还 Redis——**只有 EXPIRED 产生 discarded**）；
  **EVICTED 是 Pool 回收事件，不是 Lease 状态**：MAX_POOLS 压力下只淘汰无 ACTIVE Lease 的
  空池（CLOSED remaining=0、EXPIRED 已计数 ⇒ 零库存损失）；无 CLOSING 归还态
- **V1 不自动 RETURN**（RETURN_LEASE Lua 已实现、协议冻结，请求路径不调用）；无 idle scanner、
  无 max_lifetime（本地 max_age=2×window 已实现，属 Pool 回收维度）、无 Worker 接管、无库存补偿
- **Redis Lease 元数据 TTL（`LEASE_TTL_MS=3600000`，内部常量，非用户配置）只约束 Redis 侧记录的
  过期，不代表库存自动归还**
- 守恒不变量：`remaining + consumed = granted`（lease-unit 50 断言守护，含无 yield 探针）
- **不变量分层**：生产代码控制路径（单在途标志 + 非 yield 的 register/TAKE/状态翻转片段）
  维护不变量；`_counters` 账目随状态翻转同步维护（discarded 只计一次）；
  **`invariants()` 是测试主动调用的校验函数（lease-unit / algorithm-lease-unit / smoke /
  探针脚本），不是生产运行时断言——生产路径不调用它**

## 8. 库存账目（关口二冻结恒等式）

- **全局恒等式**：`confirmed_granted = consumed + outstanding + discarded`
  （confirmed_granted 只含 Worker 已收到并登记的 GRANT；每次状态翻转 + 移出 active +
  计数在非 yield 同片段完成 ⇒ discarded 不重复计数）
- **uncertain 单列**：GRANT 超时/断连（Redis 可能已扣、Worker 未登记）不计入恒等式，
  不重试不登记（冻结语义）；少发方向，单次 ≤ batch
- Worker 崩溃后：`granted = consumed + lost`（outstanding 在崩溃后归类 lost）
- 实测样本（Phase 6.5 worker-crash-e2e）：崩溃前 `10 = 4 + 6`；崩溃后 `10 = 4 + lost 6`；
  全局 `Σgranted=100 = HTTP 放行 94 + lost 6`（无接管/补偿/重新授权）
- **注意**：不能把聚合的 `granted − consumed` 全部认定为 outstanding——其中可能混有
  响应丢失等未确认部分；Phase 7 账目中该差额（7848/3.1%）按"未消费/未确认差额"口径报告。
  V1 不实现精确实时 lost 审计（Deferred）。

## 9. EVALSHA 脚本管理（Phase 2 冻结）

- 懒加载：`init_worker` 零 Redis IO，首次调用触发 `SCRIPT LOAD`；Worker 级缓存 SHA
- **仅明确 NOSCRIPT 触发 LOAD + 重试恰一次**；超时/断连/普通错误原样透传——**绝不当作 NOSCRIPT**
  （防止重复执行已成功的扣减）；重试后仍 NOSCRIPT ⇒ 明确失败
- 实证：Phase 7 全程 SCRIPT_LOAD=0（87 组）+ script-cache-selfheal-e2e（FLUSH 后三模式自愈）

## 10. 故障处理

| 场景 | 行为 |
|---|---|
| 连接拒绝/执行超时 | fault_tolerant=false（默认）⇒ 503 Fail-close；true ⇒ 降级放行 + `X-RateLimit-Status: degraded` |
| 故障响应伪装 | **不允许**：Redis 异常走故障分支，绝不返回 429 |
| GRANT 超时（不确定） | 不盲目重试、不登记本地库存；Redis 可能已执行 ⇒ 库存损失方向 |
| 已确认本地库存在故障期 | 正常 TAKE（本地零 IO，与 Redis 无关）；耗尽后新 GRANT 进故障分支 |
| 故障恢复后 | 独立请求正常申请；不重复授权（Phase 6.4 fault-recovery 实证记录增量恰 +1） |

## 11. 配置指纹与 Pool 隔离

见 §5。实测（Phase 6.3）：五维度（limit/window/burst/limit_by/header_name）各自变化 ⇒ 不同 Pool；
batch 变化 ⇒ 同 Pool；真栈配置变更后新配置首请求不复用旧库存。

## 12. 性能权衡（引用 Phase 7 正式报告，勿视为重测）

- 收益（RPS=1000 干净轮均值，Worker=2）：授权命令 20001→2002（约 9.99:1，约减少 10 倍）、
  Redis 总 QPS 4773→869（**下降约 81.8%**）、Redis CPU −73%、Kong CPU −23%；
  p50/p95 改善（0.66/1.41 → 0.50/1.16ms）
- p99 未改善（80–104ms 尾部由共享宿主机环境噪声支配，因果归因 NOT VERIFIED）
- 代价：库存留存敞口（Σgranted 255800 − 已消费 247952 = 7848 未消费/未确认差额，3.1%；崩溃时损失）、
  batch 粒度时序精度、本地突发消费特征
- 原始数据：`bench/raw/phase7/`；实验协议：`docs/bench.md`

## 13. V1 限制与 Deferred

| 类别 | 状态 |
|---|---|
| 自动 RETURN（RETURN_LEASE 接线）、idle scanner、Worker 接管、库存补偿 | **Deferred（未实现）** |
| 本地 Pool 生命周期回收（MAX_POOLS=10000/Worker、max_age=2×window 过期、空池 EVICTED 淘汰、60s Timer） | **已实现（关口二/三冻结；discarded 单次计数；invariants() 为测试校验函数）** |
| Redis Cluster（脚本缓存按节点、多键同 slot——键层同 slot 已由关口四任务 A 实现）与 HA/主从切换验证 | **键层已修；Cluster 行为未验证** |
| Prometheus 指标导出 / Tracing（`_counters` 仅为内部基础） | **未实现** |
| 长稳（>24h）与内存曲线 / Worker RSS | **未执行** |
| `LEASE_TTL_MS` 配置化 | V1 设计保留为常量（Phase 5 引入归还时再评估） |
| K8s / 生产 HA 部署 | 本仓库仅为 Docker Compose 验证环境 |
| N1（维度值 256 截断碰撞）/ N2 | **维持记录，未经批准不实施** |

生产边界须知（Redis 单实例切换窗口、path 高基数、清库不同步、额度头本节点视角等）见
`docs/design.md` 第 8、9 节与 `docs/DEPLOYMENT.md`。
