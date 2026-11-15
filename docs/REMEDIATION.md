# REMEDIATION 记录（rate-limit-advanced）

- 基线：`c9e05fc9fb8079d96c797f069e4aeb068ee7e2ce`（tag `baseline-c9e05fc` 已打）
- 分支：`remediation/hardening`（已从基线创建；本文件与两个探针脚本已提交并推送 origin，提交号见文末"提交状态"）
- 关口一状态：**补测完成**（本文档"关口一补测证据"节）。基线回归 16 个入口全部 PASS；内存探针已跑（实测）；并发探针已跑（Lua 协程交错模型，真实 OpenResty 并发验证 NOT VERIFIED）；Worker RSS NOT RUN。
- 关口二状态：**最终冻结**（见"关口二最终冻结"节；MAX_POOLS=10000、max_age=2×window、60s Timer 清理、方案 B 均已固化）。
- N3（Cluster CROSSSLOT）：**未获授权，保持只记录不修改**。

---

## 关口一补测证据（2026-11-15，分支 remediation/hardening，基线未修改）

### 执行环境

- Docker Compose：`kong:3.6` ×3（kong1/kong2/kong3，每副本 2 Worker）+ redis + echo（全部 Up/healthy）
- Lua 测试执行方式：`docker compose cp test/<x>.lua kong1:/tmp/<x>.lua && docker compose exec -T kong1 resty /tmp/<x>.lua`（Shell 包装：`test/*.sh` 均为此模式，属仓库既有入口，无新建包装）
- LuaJIT 2.1.0-20231117（kong1 容器内）

### 基线回归（命令 = 各 `bash test/<x>.sh`，均为仓库既有脚本；原始输出已留存在本轮执行日志）

| 测试入口 | 类型 | 断言数 | 状态 |
|---|---|---|---|
| evalsha-unit.sh | 单元 | 8 | PASS |
| lease-unit.sh | 单元 | 25 | PASS |
| algorithm-lease-unit.sh | 单元 | 17 | PASS（运行期 `_G write guard` warn 来自测试 stub 写全局 kong，非失败） |
| config-isolation-unit.sh | 单元 | 15 | PASS |
| lease-grant-smoke.sh | 真 Redis smoke | 4+7 | PASS |
| lease-redis-matrix.sh | Redis 裸跑矩阵 | 50 | PASS |
| lease-isolation.sh（lease-iso.lua 双 VM） | 隔离 | 7 | PASS |
| concurrent-lease-e2e.sh | 真 OpenResty 多 Worker E2E | 17 | PASS（含 270 并发实测：GRANT=10、Σgranted=100、HTTP 放行=100） |
| lease-exhaustion-e2e.sh | E2E | 11 | PASS |
| config-isolation-e2e.sh | E2E | 14 | PASS |
| algorithm-lease-e2e.sh | E2E | 15 | PASS |
| fault-recovery-e2e.sh | E2E | 14 | PASS |
| handler-fault-e2e.sh | E2E | 26 | PASS |
| lease-timeout-uncertain-e2e.sh | E2E | 22 | PASS |
| script-cache-selfheal-e2e.sh | E2E | 15 | PASS |
| worker-crash-e2e.sh | E2E | 16 | PASS（账目：Σgranted=100=HTTP 放行 94+lost 6） |

汇总：**16 个入口全部 PASS，0 FAIL，0 NOT VERIFIED**（修复前基线）。

### 探针 1：test/lease-memory-baseline.lua（新增文件，只读生产代码）

- 命令：`docker compose exec -T kong1 resty /tmp/lease-memory-baseline.lua`
- 场景：10 万个不同 pool_key，每 pool 登记 1 个 Lease（granted=10）并消费 3。
- 原始输出（实测）：
  - baseline_heap_kb=262.5 → after_alloc=67504.9 KB → GC 后不变（67504.9，对象仍存活）→ `lease.reset()` 后 1305.8 KB（**对象可回收性实测证据**）
  - delta=67242.4 KB / 10 万 pool ⇒ **689 B/pool（推导，含 1 个 ACTIVE Lease + pool 结构）**
  - stats 与 invariants：leases=100000 granted=1000000 consumed=300000 active=100000 local_remaining=700000，恒等成立，invariants=true → RESULT: pass=1 fail=0
  - 附加 inline 实测（同命令一次执行，非文件）：同 pool 追加第 2 个 Lease 的边际成本 = **323 B/Lease（推导）**
- 内存指标含义（按补充约束 2 分层声明）：
  - `collectgarbage("count")` = **LuaJIT GC 堆 KB**，仅 Lua 对象；不含 nginx、不含进程 RSS、不含其他 Worker。
  - 本探针属**层次 1（Lua 单元探针）**：只证明对象生命周期/可回收性与 Lua 堆成本。
  - **层次 2（真实 Worker 内存）NOT RUN**：需 10 万不同维度值的真实流量（现 k6/latency.js 打固定 /echo，无按请求维度变化），需新增按 header 变维的 k6 场景——超出本轮允许新增文件范围，待授权后执行（命令草案见遗留问题）。
  - **层次 3（长稳）NOT RUN**。
  - 不得用本探针 GC 数字代替 Worker RSS（补充约束 2 已遵守）。
- 对 MAX_POOLS 估算的校准：见关口二 §2"校准"。

### 探针 2：test/lease-concurrent-grant-probe.lua（新增文件，只读生产代码）

- 命令：`docker compose exec -T kong1 resty /tmp/lease-concurrent-grant-probe.lua`
- 注入方式：`lease._transport` 换成会 `coroutine.yield` ×TICKS 的假传输层（与 algorithm-lease-unit.lua 注入手法同源）；协程只在传输层内 yield，yield 点位置与 cosocket 一致；TAKE/登记段保持非 yield。
- **真实性声明：调度器是普通 Lua 循环，不是 OpenResty cosocket/事件调度 ⇒ 本探针为 Lua 协程交错模型，真实 OpenResty 并发验证 NOT VERIFIED**。真实环境对照数据点（实测，来自 concurrent-lease-e2e.sh）：270 并发 / 6 Worker ⇒ GRANT 总数=10、Σgranted=100、无堆积（到达分布在秒级 vs Redis RTT 毫秒级）。
- 统计口径：在途 GRANT=已进入 transport 未拿到响应的调用数；登记 Lease 数=pool.leases 长度；confirmed_granted=Σgranted；consumed=tokens_consumed；outstanding=local_remaining；uncertain_lost=0（transport 恒成功）。
- 原始输出（实测）：
  - burst（N 全部同时进入 GRANT，batch=10，TICKS=5）：
    | N | grant_calls | max_inflight | leases | confirmed_granted | consumed | outstanding |
    |---|---|---|---|---|---|---|
    | 2 | 2 | 2 | 2 | 20 | 2 | 18 |
    | 10 | 10 | 10 | 10 | 100 | 10 | 90 |
    | 50 | 50 | 50 | 50 | 500 | 50 | 450 |
    | 100 | 100 | 100 | 100 | 1000 | 100 | 900 |
  - steady（每调度步新到 1 个请求，TICKS=5）：grant_calls=10，max_inflight=5，leases=10，confirmed_granted=100，consumed=100，outstanding=0。
- 结论（全部标注 NOT VERIFIED，待真实 E2E 复核）：
  1. **在途 GRANT 无上限**：burst N=100 ⇒ 单 pool 并发 100 笔在途、登记 100 个 Lease。
  2. **单 Worker 单 key 库存可远超 batch**：N=100/batch=10 ⇒ confirmed_granted=1000，outstanding=900（=90×batch）。仅受并发请求数限制，不受任何代码上限约束。
  3. **在途数 ≈ 到达率 × RTT（steady 场景）**：到达间隔大于 RTT 时在途≈1~5，库存自然有界；只有突发同时到达才堆积——与 concurrent-lease-e2e 实测"秒级到达分布下无堆积"一致。
  4. 账目恒等式在所有场景成立：confirmed_granted = consumed + outstanding + 0。

### 环境跑不了 / 未跑项

- Worker RSS（层次 2）：NOT RUN。待授权新增按请求变维的 k6 场景后执行：`k6 run` 高基数 header 压 kong1 → 采样 `/proc/<worker pid>/status` VmRSS 前后对比。
- 长稳（层次 3）：NOT RUN。
- 并发真实环境探针（真实 cosocket + ngx.sleep 注入于 Kong Worker 内）：NOT VERIFIED。现有 resty 模型只能证明协程交错下的行为序，不能替代。

## 关口二最终冻结（2026-11-15，等待关口三实施）

以下参数与方案**冻结**，关口三按此实施，不得单方面偏离：

| 冻结项 | 冻结值 | 备注 |
|---|---|---|
| MAX_POOLS | **10000 / Worker**（Lua 常量，不改 schema） | 内存实测校准：6.9 MB/Worker 均值、10.1 MB 最坏（2 Lease/池） |
| max_age | **2×window**（每 Pool 首次 GRANT 时的配置快照） | 与桶键 TTL 同值，防跨桶纪元 |
| Timer 清理 | **init_worker `ngx.timer.every(60, sweep)`**（60s） | 每 tick ≤64 Pool、pcall 包裹、exiting 检查、只碰空闲 Pool |
| 并发 GRANT | **方案 B：单 Pool 单在途 GRANT + 其余并发退化为 batch=1 直连** | 直连 = `redis_mod.grant(conf, key, 1, ...)`，不登记本地库存 |
| 账目恒等式 | **confirmed_granted = consumed + outstanding + discarded** | uncertain_lost 单列，不入式，不重试不登记（语义冻结） |

**冻结的行为裁决（相对上一版草案的变更，diff 形式）**：

```diff
- 淘汰顺序：优先淘汰无 ACTIVE Lease 的 Pool；无可淘汰时按 last_used
- 最旧淘汰含 ACTIVE Lease 的 Pool，remaining 计入 discarded。
+ 淘汰顺序：只淘汰无 ACTIVE Lease 的 Pool（零库存损失）。
+ MAX_POOLS 达上限且不存在可淘汰的空闲 Pool 时，不驱逐任何 ACTIVE
+ Pool；该请求直接走 batch=1 直连降级（不 429、不 503，见 §2）。
+ ⇒ EVICTED 不再产生库存损失；discarded_tokens 唯一来源 = EXPIRED
+   Lease 的未消费 remaining；不向 Redis 自动归还。
```

- EVICTED 定义相应修订：EVICTED 仅表示"空闲 Pool 因 MAX_POOLS 压力被整体删除"，无 Lease 对象损失；`_counters.evicted` 记被删 Pool 数（诊断用），不参与账目恒等式。
- 保持不变（继续有效）：Worker RSS（层次 2）、长稳（层次 3）、真实 OpenResty 并发验证 = NOT RUN / NOT VERIFIED，关口三修复后必须补真实验证。
- **N3（Redis Cluster CROSSSLOT）：本轮明确不授权修改**。保持"已确认的条件性兼容性问题"记录；`redis/*.lua`、`lib/redis.lua` 内嵌脚本、已冻结 Redis Lua 协议不动，等待后续单独批准。
- 本轮不修改生产代码、Redis Key、Lua 协议、Schema。

---

## 关口二：整改设计（本关不改任何代码；仅新增本文件）

### 改了什么

无代码改动。仅新增 `docs/REMEDIATION.md`。以下设计基于对当前代码的直接核实，文件均在 `kong/plugins/rate-limit-advanced/` 下（下文省略前缀）。

### 设计前提：已核实的代码事实（关口一线索的落点核实）

| 线索 | 核实结果 | 证据（文件:行号） |
|---|---|---|
| a. register 只增不删、无回收、无 timer | **确认** | `lib/lease.lua:124-125`（leases/active 各追加一次）；`:156-158`（耗尽仅从 active 摘除，对象保留在 leases）；`_M._pools` 全文无删除点；`handler.lua:18-20`（init_worker 仅打日志）；全目录 grep 无 `ngx.timer` |
| b. check_lease 本地无库存直接 GRANT、无合并/加锁 | **确认** | `lib/algorithm.lua:350`（take→NEED_GRANT）→ `:370`（直接 lease.grant）→ `lib/redis.lua:722`（EVALSHA，cosocket yield 点）→ `:239`（register 登记）。并发请求各自走完该链 ⇒ 同 pool 多 Lease 并存 |
| c. lkey 无 hash tag；脚本只用调用方 KEYS | **确认** | `lib/redis.lua:715`（`lkey = key_prefix .. ":lease:" .. lease_id`，无大括号）；桶键带 hash tag（`lib/algorithm.lua:139`）；GRANT_LEASE 仅用 `KEYS[1]/KEYS[2]`，RETURN_LEASE 仅用 `KEYS[1]/KEYS[2]`，脚本内部不构造 key（`lib/redis.lua:175-282, 292-399`）。**后果：Redis Cluster 下两 key 大概率不同 slot，EVAL 多键报 CROSSSLOT，GRANT_LEASE 全路径失败 → fail-close 503** |
| d. dim_value 直接拼接未转义；未认证回落 "anon" | **确认** | `lib/algorithm.lua:133`（`dim .. "=" .. dim_value(...)` 直接拼接）；`:66-68`（consumer 为 nil ⇒ "anon"） |
| e. Redis Lease 元数据的读取方 | **确认**：生产代码无读取方。RETURN_LEASE 脚本已注册但无任何调用点（`lib/redis.lua:292` 定义，grep 全目录无 `return_lease` 调用）；仅测试读：`test/worker-crash-e2e.sh:85,123`（`--scan --pattern 'kong:rl:lease:*'`）、`test/lease-grant-smoke.lua`（HGET 取证） |
| f. Redis 脚本参数无本地时间；ngx.now 全用途 | **确认**。三个脚本 ARGV 仅为 batch/lease_ttl_ms/lease_id/pool_key/rate/capacity/bucket_ttl_ms、rate/burst/want/ttl_ms、n/rate/burst/ttl_ms——**无时间参数**；脚本内一律 `redis.call('TIME')`（`lib/redis.lua:35,94,241,379`）。本地 `ngx.now()` 用途全表：`lib/lease.lua:69`（随机种子）、`:121`（created_at）、`lib/algorithm.lua:266,341,433`（Reset 头近似）、`handler.lua:70`（429 Reset 头）。**结论成立：本地时间从不参与 Redis 侧授权计算** |
| g. 读内部结构的 5 个测试 | **确认**，各自意图：`lease-unit.lua`（register 字段/守恒/TAKE 原子性/GRANT 四分类，直接读 `lease._pools[PK].leases/active`）；`algorithm-lease-unit.lua`（三模式接线矩阵，`_transport` 注入 + redis_mod monkeypatch）；`config-isolation-unit.lua`（pool_key 指纹隔离 + Pool 层隔离）；`lease-grant-smoke.lua`（真 Redis GRANT 链路 + CLIENT PAUSE 不确定方向取证）；`lease-iso.lua`（双进程 = 双 VM 隔离，读 `_pools` 输出） |
| h. design.md 残留与 README 示例 | **确认**：`docs/design.md` 仍有 4 处 shared dict 描述（:64,:240,:281,:360，与 Phase 8 删除 store.lua 后的现状不符）与 6 处 `⟨TODO⟩`（:288,:330,:348,:381,:395 等）；README `:53`（limit=100 示例）、`:70`（3 副本×2 Worker）、`:104`（batch=10）、`:124`（kong.yml limit=1000）。合理性评估见 §7 新问题 |

### 1. 状态与账目

**Pool 生命周期**

- 创建：`register()` 首次遇到 pool_key 时创建（`lib/lease.lua:86-93`）。Pool 上记录：`active` 集合、`last_used`（TAKE 时一次赋值）、`max_age`（该 pool 首次 GRANT 时的配置快照，等于 2×window，**毫秒**）、`sweep_seq`（防重复回收标记）。**单位约定（冻结）**：`created_at` 与 `ngx.now()` 为**秒**，`pool.max_age` 为**毫秒**；全部过期/回收判断统一使用 `created_at + pool.max_age / 1000 < ngx.now()`。
- 回收：满足**全部**条件时整池删除：(1) `#pool.active == 0`；(2) 距 `last_used` ≥ `max_age / 1000`（秒口径，即桶 TTL 窗口内无人再触碰）。删除点仅在清理流程（§4），不在 TAKE/GRANT 热路径上做 O(n) 扫描。
- 回收边界：删除 pool 对象（table + 数组）整体释放，不做逐步置 nil。

**Lease 终态定义**（对象进入终态后**立即解除引用、由 GC 回收**；终态不再保留对象——这是对现行 D2"对象保留作诊断"的修改点，理由：诊断清单正是无界增长源，历史改由计数器承载）

- `ACTIVE`：在 pool.active 集合内，remaining > 0，未超 max_age。
- `CLOSED`：remaining 减至 0，从 active 摘除（现行语义不变，`lib/lease.lua:155-158`）。
- `EXPIRED`：`created_at + max_age / 1000 < ngx.now()`，从 active 摘除；**remaining>0 时计入 discarded（discarded 的唯一来源）**，remaining=0 时仅摘除。**不向 Redis 自动归还**（V1 无 RETURN）。
- `EVICTED`（冻结修订版）：仅表示"空闲 Pool 因 MAX_POOLS 压力被整体删除"——**不驱逐含 ACTIVE Lease 的 Pool**，故 EVICTED 无库存损失、无 Lease 对象进入该终态；`_counters.evicted` 记被删 Pool 数（诊断用），不参与账目恒等式。

终态可见性：`_counters` 增加 `expired` / `evicted` / `discarded_tokens` 三个数字计数器；`stats()` 输出它们。不保留终态对象。

**运行时库存与历史统计分离**

- 运行时 = pool.active 集合（可消费库存）。
- 历史 = `_counters` 数字计数器（leases / tokens_granted / tokens_consumed / closed / expired / evicted / discarded_tokens）。计数器为 number，自身有界（Lua double 上限 2^53，且 lifespan 内不可达），**不存在无界增长**。原来承担"历史"职责的 `pool.leases` 诊断清单取消。

**账目恒等式及适用范围（按本关要求口径）**

```
confirmed_granted = consumed + outstanding + discarded
```

- `confirmed_granted` = `tokens_granted` 计数器 = Σ 已成功 register 的 Lease 的 granted。**只含 Worker 已收到响应并登记的 GRANT**。
- GRANT 超时/断开/畸形（Redis 可能已扣桶已建记录，Worker 未登记）单列 `uncertain_lost`，**不进入上式**。现行"不重试、不登记"语义不改（`lib/lease.lua:236-243` 原样保留，含 register 失败归类 uncertain 的既有处理）。
- 恒等式**精确成立**的条件：EXPIRED 摘除时把 remaining 一次性转入 discarded_tokens；TAKE 递减与计数器在同一段非 yield 片段内更新（现行 `lib/lease.lua:152-154` 已如此）。逐对象守恒 `granted = consumed + remaining` 在摘除瞬间转为 `granted = consumed + discarded`。EVICTED 不产生 discarded（冻结：不驱逐 ACTIVE Pool）。
- **不得宣称**该恒等式覆盖 uncertain_lost：`granted(全局) = consumed + outstanding + discarded + uncertain_lost` 中 uncertain_lost 只能由 Redis 侧与 Worker 侧对账估计（现状无对账手段），文档只写"允许损失，方向保守（少放行）"。

**Redis Cluster 下的账目口径**：CROSSSLOT（前提 c）修复前，Lease 模式在 Cluster 上不可用；修复方式（给 lease key 加 hash tag）**属于对 `redis/*.lua` 双源脚本的参数/key 构造改动**，按整改边界需先报告等确认，本设计不擅自实施（见 §7-N3 与遗留问题）。

### 2. Pool 上限与淘汰

**MAX_POOLS = 10000 / Worker（Lua 常量，不改 schema 字段）**，依据（单点实测 + 推导，校准数据见"关口一补测证据"探针 1）：

- 单 Pool 固定成本：**实测校准**——1 个 ACTIVE Lease 的 pool 全成本 689 B/pool（探针 1），每追加 1 个 Lease +323 B（推导，inline 实测）。
- 上限内存（推导，基于实测单点）：10000 Pool × 平均 1 ACTIVE Lease ≈ 10000 × 689 B ≈ **6.9 MB/Worker**；最坏（每 Pool 2 Lease）≈ 10000 × 1012 B ≈ **10.1 MB/Worker**。与此前估算（7/14 MB）一致，取实测校准值。
- 为什么不是更小值：正常业务基数（consumer×ip×path 组合）通常 < 数千；10000 保证正常流量**永不触发淘汰**，淘汰只对攻击性高基数生效。
- 为什么不是更大值：上限的目的是封顶攻击内存，而非承载正常负载；更大值让攻击内存线性增长。
- 明确：**每 Worker 上限**（Worker 私有 Lua VM，结构上无共享）。N Worker 集群总本地库存 = N × 10000 Pool × batch——与全局限流的超发无关（全局权威在 Redis 扣桶，见 §5 的澄清）。

**淘汰顺序（冻结版）**：只淘汰**没有 ACTIVE Lease 的 Pool**（零库存损失）。

**达上限且无可淘汰 Pool 时的降级路径（冻结版，不驱逐 ACTIVE Pool，不 429、不 503）**：该请求退化为**不登记本地库存的直接授权**——复用现行 batch=1 路径 `redis_mod.grant(conf, key, 1, ttl_ms, rate, burst)`（`lib/algorithm.lua:450`，want=1），granted≥1 ⇒ 放行（remaining 按该路径既有口径 = granted-1 = 0）；granted=0 ⇒ 既有 429 语义（这来自**桶空**，不是攻击者制造的 Pool 压力）；Redis 失败 ⇒ 既有 fail-close/fail-open 分支。请求语义与 batch=1 完全一致，攻击者无法靠高基数 key 把正常用户打到 429/503——Pool 压力只影响"该请求是否享受本地库存加速"，不影响授权结果。该路径不进 Lease 账目（无 Lease 登记），在日志中打 `pool_cap_degraded` 标记便于审计。

**TAKE 热路径约束**：TAKE 内只做既有遍历 + `pool.last_used = now` **一次字段赋值**；不建链表、不做 O(n) 维护。**过期判定（冻结修订）**：TAKE 对扫描到的候选 Lease 做一次 O(1) 过期比较（`created_at + pool.max_age / 1000 < ngx.now()`，秒/毫秒约定见 §1，详见 §10）——遇到过期候选即摘除并继续，遇到首个未过期可消费 Lease 即消费；稳态下头部候选未过期 ⇒ 热路径无额外成本。不检查过期的旧表述废止（它会让持续被访问的 Pool 中过期 Lease 永久存活并被消费——Timer 只清空闲 Pool、GRANT 惰性清扫只在 NEED_GRANT 时触发，二者都覆盖不了热 Pool）。

**淘汰执行点与上限**：仅在 (1) GRANT 路径发现 `_pools` 计数 ≥ MAX_POOLS 时触发一次、(2) init_worker timer 里触发；每次处理 ≤ 64 个 Pool，不全量扫描。

**淘汰与超发**：EVICTED 丢弃的 remaining 是 Redis 已扣、Worker 未消费的库存——丢弃即损失，方向保守（少放行），**不会超发**；不向 Redis 自动 RETURN（V1 无 RETURN，`RETURN_LEASE` 保持未接线）。

### 3. 过期

**max_age = 2×window（每个 Pool 在首次 GRANT 时的快照，非全局常量）**，依据：

- 与桶键 TTL 同值（现行 `lib/algorithm.lua:342`：`ttl_s = max(1, floor(window×2))`）。窗口含义：一个 Lease 的库存从创建起，其对应的桶最迟在 2×window 后整体消失；桶消失后新桶从满桶起步，若旧本地库存跨过桶生命周期存活，会在新纪元上叠加旧库存（时间分布上的突发，不是超发——这些令牌仍是旧纪元 Redis 扣过的）。max_age = 2×window 保证本地库存不跨桶纪元。
- 也覆盖消耗节奏：auto batch ≤ limit/2，单批最慢消耗完需 ≤ window（Phase 6 报告口径 720s < 2×window=7200s@limit=100/window=3600；推导）。
- **概念区分（写入文档时必须分开表述）**：
  - 桶 refill：Redis 侧按 `TIME` 持续生成令牌（`lib/redis.lua:47-51`），是**唯一令牌来源**。
  - 桶 TTL：Redis 侧 key 生命周期（PEXPIRE）。
  - 本地 max_age：Worker 侧库存的**丢弃**计时器——只减少可用库存，从不生成库存。
- **时间源结论（已核实，见前提 f）**：Redis 脚本参数无本地时间，Redis 侧授权只依赖 `redis.call('TIME')`。因此：本地时钟前跳 ⇒ max_age 提前到点 ⇒ 只会**早丢弃**；回拨/节点间偏差 ⇒ max_age 推迟 ⇒ 库存活得略久，仍是 Redis 已扣的令牌，**不创造令牌**。结论：**累计放行量 ≤ Redis 累计确认扣减量（含直接授权路径的扣减），与本地时钟行为无关**。
- **文档表述边界（按补充约束 3）**：上句成立的前提是——Redis 授权状态连续有效、无已确认写入回滚、统计口径一致。以下情形必须单列，不得被该句吸收：
  1. **Redis 主从切换/数据回滚**：已扣桶回滚到旧值 ⇒ 同一批令牌可能被再次授予 ⇒ 这是**真正的超发**，属于 Redis 层故障域，本设计不宣称防护。
  2. **配置指纹变化**：新旧 Bucket 并存（`lib/algorithm.lua:136-139` 指纹隔离），旧 Pool 按 max_age 自然消亡——并存期总放行是"新旧两个纪元各按各自配额"，文档如实描述，不算超发也不算防护目标。
  3. **本地时钟安全 ≠ 系统全故障域安全**：本地过期机制的全部作用是"丢弃"，它不提供对 Redis 侧故障的超发防护。
- 回拨导致库存存活超过 max_age 的后果定性：**既有突发放大语义的延长**（Worker 拿着旧库存继续放行，直到库存耗尽），不是新的超发。不引入 FFI 单调时钟（Phase 5 已 DEFERRED，本整改不重启该工作）。

### 4. 清理

- **TAKE/GRANT 惰性清理**：GRANT 前（非 yield 片段内）对**当前 pool** 做一次有上限的过期清扫：摘除 EXPIRED Lease、discarded 计数；单次最多处理 32 个 Lease，超出留给下次（GRANT 是冷路径，允许分批）。TAKE 不做全量清理，但**在扫描候选时顺带摘除过期 Lease**（O(1) 比较 + 摘除即扫过，见 §10）——热 Pool 的过期回收由 TAKE 路径承担，Timer 只兜底空闲 Pool。
- **init_worker 兜底 timer（冻结：60s）**：`ngx.timer.every(60, sweep)`（低频；间隔 60s，推导：2×window 典型 = 60~7200s，60s 粒度对丢弃时机影响可忽略）。每次 tick：
  - `ngx.worker.exiting()` 为真 ⇒ 立即 return（Worker 退出）。
  - 回调整体 `pcall` 包裹，单池异常 ⇒ 记 err 日志并跳过该池，不影响其他池。
  - 只处理"空闲候选"：`last_used` 距今 ≥ `max_age / 1000`（秒口径）的 Pool，且每 tick ≤ 64 个（按 last_used 最旧优先），不全量扫描。
  - **与请求路径不重复回收**：请求路径只碰"当前请求的 pool"；timer 只碰"空闲 pool"（last_used 老于阈值 ⇒ 没有请求在用）。两者集合不相交，无需锁。
  - timer 与请求协程的交错安全性：清理全部是纯 table 操作，无 yield 点，任一清理片段与 TAKE/GRANT 的非 yield 片段互斥于协程调度（现行原子性论证同构，`lib/lease.lua:8-10` 注释的证明方式直接复用）。
- 兜底第二职责：达 MAX_POOLS 时的淘汰也可由该 timer 承担，降低请求路径触发概率。

### 5. 并发 GRANT（机制已核实；量化来自探针实测 + Lua 协程模型，真实环境结论 NOT VERIFIED）

**机制（已核实，前提 b）**：check_lease 本地 miss ⇒ 每个并发请求各自发起 GRANT（cosocket yield，`lib/redis.lua:722`），无在途合并、无上限。

- **在途 GRANT 定义**：已发出 EVALSHA、尚未收到响应的 GRANT 调用数（每 Worker 每 pool 计）。当前代码无任何计数器，也无上限。
- **实测（Lua 协程交错模型，NOT VERIFIED，见补测节探针 2）**：
  - burst N=100、batch=10：max_inflight=100，单 pool 登记 100 个 Lease，confirmed_granted=1000，outstanding=900（=90×batch）——**单 Worker 单 key 库存上限 = 并发请求数 × batch，代码内无任何约束**。
  - steady（到达间隔 > RTT）：max_inflight=5，leases=10，库存自然有界 ⇒ 堆积只在突发同时到达时出现。
  - **真实环境对照（实测，concurrent-lease-e2e.sh）**：270 并发 / 6 Worker，GRANT 总数=10、Σgranted=100——秒级到达分布下无堆积。两数据不矛盾：真实部署中堆积概率 = 同 pool 请求到达密度 × Redis RTT；仍需真实 OpenResty 探针复核（NOT VERIFIED）。
- **危害澄清（不变）**：总量不超发——每次 GRANT 都被 Redis 原子扣桶；实际危害 = (1) 内存堆积（由 §2 MAX_POOLS 兜底）、(2) 突发放大（未来配额提前借入本地）、(3) 崩溃损失敞口变大。

**方案比较**：

| 方案 | 描述 | 吞吐/延迟 | 语义影响 | 评估 |
|---|---|---|---|---|
| A 保持现状 | 无合并无上限 | miss 风暴时全部并发打 Redis（本来也要打） | 不变 | 实测（NOT VERIFIED）：burst 下单 pool Lease 数=并发数、库存=并发数×batch，内存/突发/损失敞口无界（由 §2 MAX_POOLS 兜底内存），突发放大持续存在 |
| B 单 Pool 单在途 GRANT + 其余并发退化为直接授权 | pool 记 `inflight` 标志；已置位时并发请求直接走 `redis_mod.grant(want=1)`（不登记） | 热路径不变；miss 路径多出的直接授权本就是每请求一次 Redis，与 batch=1 同成本 | 请求语义不变（授权仍由 Redis 桶决定，空桶仍 429）；不重试/不登记语义对该降级路径天然成立 | **推荐（探针数据强化了理由）**。steady 实测表明到达间隔 > RTT 时在途本就有界 ⇒ B 只在突发窗口生效，代价极小；O(1) 记账、无协程协调。**每 Pool active Lease 数上界 = 1**（冻结）：GRANT 仅在 take 返回 NEED_GRANT（active 空）时发起；单在途标志使同一 Pool 同一时刻至多一笔 GRANT；标志置位期间的并发请求走直连不登记；GRANT 返回后的 classify + register 与标志清除在同一段非 yield 片段内完成（中间无 yield 点）⇒ 任意时刻 `#pool.active ≤ 1` |
| C 合并等待 | 后续请求 yield 等待在途 GRANT 结果共享库存 | 引入协程等待/超时传播，实现复杂 | 请求延迟耦合在途 GRANT 的 RTT | 不推荐：复杂度与收益不成比例，且等待语义要新造 |
| D 每 Pool Lease 数上限 + 超限退化直连 | 与 B 等效但记账对象不同（数 Lease 不数在途） | 同 B | 同 B | 可作 B 的实现变体；B 的标志更简单 |

**推荐 B，理由**：退化路径复用**已经过 66 断言验证的 batch=1 路径**（`lib/algorithm.lua:448-484`），fail-close/429/头部语义全部现成；实现面最小（一个标志位 + 一处分支）；不改变任何冻结语义。**实施风险需设计确认**：inflight 标志必须在 GRANT 的所有返回路径（含超时异常）上清除，否则单 pool 永久降级——实现时以非 yield 的成对 set/clear 保证。

### 6. 测试方案（三类分开，不得互代）

**单元（resty，现有框架扩展）**
- 新增断言面：EXPIRED 摘除 + discarded 计数；EVICTED 摘除 + discarded；MAX_POOLS 降级直连（batch=1 路径被调、不登记）；Pool 回收（active 空 + last_used 老于 max_age/1000）；**方案 B 上界：burst N 并发（探针同款协程注入）下 transport 恰被调 1 次、直连 stub 被调 N−1 次、结束时 `#pool.active ≤ 1`**；账目恒等式 `confirmed_granted = consumed + outstanding + discarded` 全路径成立；uncertain 不入恒等式（既有断言保留）。
- `_M.invariants()` 扩展校验新计数器与逐对象求和无漂移（现 `lib/lease.lua:295-340` 框架内扩展）。

**同步修改 5 个读内部结构的测试（保持各自原意图）**
- `lease-unit.lua`：意图 = 结构与守恒。修改点：原"全量诊断表保留对象"断言（读 `pool.leases`）改为"对象入终态后计数器闭环 + active 集合无残留"；守恒/原子性/GRANT 四分类断言原样保留（它们读的 active 集合与 stats 仍存在）。
- `algorithm-lease-unit.lua`：意图 = 接线矩阵。基本不动；新增"达上限降级直连、不触 GRANT_LEASE"一列。
- `config-isolation-unit.lua`：意图 = pool_key 隔离。不动（其读的 Pool 层结构在新设计中原样存在）。
- `lease-grant-smoke.lua`：意图 = 真 Redis 链路证据。不动（不读 _pools 内部，走公共 API）。
- `lease-iso.lua`：意图 = 双 VM 隔离。输出行改从 `stats()` 取（原读 `_pools` 的行等价替换），隔离结论断言不变。

**内存压力（与单元探针分开记录，不得用 GC 结果代替）**
- 层次 1 Lua 单元探针：**已跑（PASS，实测）**——`test/lease-memory-baseline.lua`，10 万 pool，689 B/pool、reset 后回收至 ~1 MB；只证明对象生命周期与 Lua 堆成本。
- 层次 2 Worker 压力：**NOT RUN**——计划：新增按请求变维的 k6 场景压 10 万不同 key，记录每 Worker `collectgarbage("count")` 与 `/proc/<pid>/status` VmRSS，修复前后同环境同规模同过程各一轮。
- 层次 3 长稳：**NOT RUN**——计划：持续创建/消费/过期/淘汰循环 ≥ 1h，观察 RSS 与 GC 计数收敛。三层结果在 REMEDIATION.md 分别记录，禁止混写。
- 明确禁止的推理："_pools 数量有界 ⇒ 内存有界"不作为结论；必须以层次 2/3 的实测数字收口（当前两者均 NOT RUN）。

### 7. 新发现问题（本关核实中发现的、线索单之外的问题）

| # | 问题 | 证据 | 风险 |
|---|---|---|---|
| N1 | header 维度值 >256 字符被截断（`MAX_DIM_VALUE_LEN`），不同长值共享 256 前缀 ⇒ 不同租户合并进同一桶/同一 Pool | `lib/algorithm.lua:22,87-89` | P2 |
| N2 | 维度值拼接无转义：值内含 `:<dim>=` 模式可与其他维度组合碰撞（如 IPv6 值含冒号、header 值任意）⇒ 跨维度串桶 | `lib/algorithm.lua:133,70-74` | P2 |
| N3 | Redis Cluster 部署下 lease key 无 hash tag ⇒ CROSSSLOT ⇒ GRANT_LEASE 全失败（fail-close 503）。修复需改 `lib/redis.lua:715` 的 key 构造（并同步 `redis/grant_lease.lua` 双源）——**按整改边界属禁改区，需你确认后才动** | `lib/redis.lua:715` vs `lib/algorithm.lua:139` | P1（仅 Cluster 部署触发） |
| N4 | `RETURN_LEASE` 脚本已注册但生产代码无调用方（死代码）。按边界不删；建议在文档标注"保留、未接线（Phase 5 恢复时使用）" | `lib/redis.lua:292,421` | P3 |
| N5 | `stats()/invariants()` 遍历全部 Pool × Lease，O(总数)；仅测试/诊断调用，无生产热路径引用 | `lib/lease.lua:267-284,295-340` | P3 |
| N6 | `LEASE_TTL_MS` 固定 1h < 桶 TTL（2×window，window>1800s 时桶比 Lease 记录活得久）；V1 无 RETURN 故无实际影响，Phase 5 接 RETURN 时会踩到 LEASE_NOT_FOUND | `lib/algorithm.lua:20,342` | P3 |
| N7 | README 示例：limit=100 + batch=10 + 6 Worker ⇒ 稳态本地库存可达 60（60% 配额提前借出），崩溃损失敞口 6×10=60；数字功能上自洽但偏激进，建议示例改 `batch=5` 或 auto（auto=floor(100/50)=2） | `README.md:53,70,104` | P3（文档） |
| N8 | design.md 残留 4 处 shared dict 描述与 6 处 `⟨TODO⟩`，与 Phase 8 后现状不符 | `docs/design.md:64,240,281,288,330,348,360,381,395` | P3（文档） |

### 8. 风险分级与实施计划表

分级原则：P0 阻断 / P1 正确性或长期稳定性 / P2 生产化缺口 / P3 文档维护性。**不全部列为必修。**

| 问题 | 涉及文件 | 风险 | 测试 | 需设计确认 |
|---|---|---|---|---|
| a. Lease 对象无界增长（leases 清单 + _pools 无回收） | lib/lease.lua、handler.lua(timer) | **P1** | lease-unit 扩展 + 内存三层 | 否（已冻结） |
| b. 并发 GRANT 无合并（库存堆积/突发放大/损失敞口） | lib/algorithm.lua 或 lib/lease.lua | **P1**（危害为内存与突发，非超发） | algorithm-lease-unit 新列 + 探针前后对比 | 否（方案 B 已冻结；仅 inflight 标志的成对 set/clear 属实现细节） |
| 新增：Pool 上限 + 降级直连 | lib/lease.lua、lib/algorithm.lua | P1 的伴生防线 | algorithm-lease-unit 新列 | 否（MAX_POOLS=10000、不驱逐 ACTIVE Pool 已冻结） |
| 新增：max_age 过期清理 | lib/lease.lua | P1 的伴生防线 | lease-unit + 长稳 | 否（2×window、60s Timer 已冻结） |
| N3. Cluster CROSSSLOT | lib/redis.lua:715、redis/grant_lease.lua 双源 | P1（条件性） | lease-grant-matrix（Cluster 环境） | **是（禁改区，需批准）** |
| N1/N2. 维度值碰撞 | lib/algorithm.lua dim_value/build_key | P2 | config-isolation-unit 扩展 | 是（转义方案会改变既有 key 形态 ⇒ 存量桶全部作废） |
| N7. README 示例数字 | README.md | P3 | 无（文档） | 否 |
| N8. design.md 残留 | docs/design.md | P3 | 无（文档） | 否 |
| N4/N5/N6. 记录性备注 | — | P3 | 无 | 否（仅记录，不改） |

**必修建议顺序**：a（无界增长）→ b（并发 GRANT）→ N3（待批准）→ N1/N2（待确认 key 形态变更的接受度）。N7/N8 可与相邻文档改动合并提交（按补充约束 5）。

### 9. 补测后设计复核（按审查要求逐项）

| 设计项 | 复核结论 | 依据 |
|---|---|---|
| MAX_POOLS=10000/Worker 内存估算 | **维持 10000，估算更新为实测校准**：6.9 MB/Worker（均值）/ 10.1 MB（最坏 2 Lease/池） | 探针 1 实测 689 B/pool、+323 B/Lease |
| max_age=2×window | **维持**。探针数据不涉及时间行为，原推导链（=桶 TTL、不跨桶纪元、只丢弃不生成）不变；Redis 脚本无本地时间的核实结论不变 | 前提 f 核实 + 探针 1/2 不冲突 |
| ACTIVE Lease 到期后库存处理 | **维持：EXPIRED 摘除、remaining 计入 discarded，不归还 Redis**。账目恒等式含 discarded 项，探针验证的 confirmed_granted = consumed + outstanding + 0 与该设计兼容（discarded>0 场景由修复后测试覆盖） | 探针 1/2 恒等式 identity_ok=true |
| 达上限 batch=1 直连降级 | **维持**。复用路径 `redis_mod.grant(want=1)` 有真实验证覆盖：algorithm-lease-e2e.sh batch=1 列 PASS（15 断言）、handler-fault-e2e.sh batch=1 fail-close/fail-open PASS——降级路径的语义基础已实测 | 本轮基线回归 |
| 单在途 GRANT + 直连降级（方案 B） | **维持推荐，理由强化**：steady 实测（NOT VERIFIED）表明到达间隔 > RTT 时在途本就有界（max_inflight=5、leases=10），B 只在突发窗口生效；burst 实测（NOT VERIFIED）量化了无约束的代价（inflight=100、库存 900=90×batch） | 探针 2 实测 + concurrent-lease-e2e 实测对照 |

账目最终口径（不变，探针实测一致）：`confirmed_granted = consumed + outstanding + discarded`；GRANT 超时/响应丢失 → `uncertain_lost` 单列，不入上式，不重试不登记（现行 `lib/lease.lua:236-243` 语义冻结不变）。

### 10. 活跃 Pool 中过期 Lease 的 TAKE 边界（澄清并冻结，不改生产代码）

**问题**：Timer 只清空闲 Pool、GRANT 惰性清扫只在 NEED_GRANT 时触发；持续有请求命中的 Pool（`last_used` 不断刷新）两者都覆盖不到——其中已超 max_age 的 Lease 会一直留在 active 集合被 TAKE 消费。危害定性：这些令牌仍是旧纪元 Redis 已扣的，**不构成累计超发**（§3 结论不变），但会使"本地库存不跨桶纪元"（max_age 的设计目的）在慢速热 Pool 上失效，属时间分布上的突发放大延长——必须修复。

**裁决 1：活跃 Pool 的过期 Lease 如何保证不再被 TAKE 消费**

- TAKE 扫描候选时做**逐候选 O(1) 过期比较**：`created_at + pool.max_age / 1000 < ngx.now()`（单位约定：`created_at`/`ngx.now()` 秒、`pool.max_age` 毫秒，§1/§2/§3 冻结值 2×window 毫秒快照）。
- 候选过期 ⇒ 调用统一摘除函数 `expire_lease(pool, lease)`（§1 EXPIRED 语义）：`state="EXPIRED"`、`discarded_tokens += remaining`、从 active 数组移除，三步在**同一非 yield 片段**内完成；随后 TAKE 继续扫描下一候选。
- 首个未过期且 remaining>0 的候选照常消费；全部候选过期/无库存 ⇒ `NEED_GRANT` ⇒ 既有 GRANT 路径（其惰性清扫与该逻辑自然衔接）。
- 时钟语义（沿 §3）：本地回拨 ⇒ 过期判定推迟（库存存活略久，突发放大延长，方向保守）；时钟前跳 ⇒ 提前丢弃新鲜库存（少放行，保守）。两向都不创造令牌。

**裁决 2：为何不引入 TAKE 热路径 O(n) 扫描**

- **TAKE 最坏扫描成本 = O(1)（严格，非摊还）**：方案 B 下每 Pool active Lease 数上界 = 1（§5 B 行冻结）。TAKE 至多检查 1 个候选：未过期且 remaining>0 ⇒ 消费返回；已过期 ⇒ `expire_lease` 摘除（active 随之清空）⇒ 返回 NEED_GRANT。不存在"扫描跳过多个候选"的路径。
- 防御性摊还论证（保留，覆盖上界被破坏的任何异常状态）：每个 Lease 至多被摘除一次（摘除后即离开 active 集合，永不再被扫到），生命周期内总摘除次数 ≤ 总登记数，总额外成本被全量 TAKE 摊平。
- `table.remove` 的移位成本：active 数组长度本身有界（方案 B 冻结后 `#active ≤ 1`；且现行代码耗尽摘除已用同一原语，`lib/lease.lua:157`），不新增量级。

**裁决 3：discarded 只计一次、恒等式不破坏**

- **单一摘除函数** `expire_lease` 是唯一入口：TAKE 路径、GRANT 惰性清扫、Timer 兜底三处全部调用它，计数逻辑只存在一份（`discarded_tokens += l.remaining` 与 `state` 置 EXPIRED、从 active 移除在同一原子片段内）。
- 防重复的机制保证：(a) Lease 对象在 active 集合中至多出现一次（既有结构不变量，`lib/lease.lua:295-340` 已断言）；(b) `state` 在计数**之前**翻转，摘除后对象离开 active ⇒ 第二个到达者（无论哪条路径）再也看不到它；(c) 三处调用点全部是非 yield 片段，协程调度保证片段间不交错（现行原子性论证复用），不存在"两条路径同时摘除同一对象"的窗口。
- 恒等式维持 `confirmed_granted = consumed + outstanding + discarded`：摘除瞬间完成 `granted = consumed + remaining` → `granted = consumed + discarded` 的转移，remaining 转出后立即离开 outstanding（active 求和口径），无双重计入。
- 验证要求（关口三测试面）：lease-unit 增加"同一 Lease 被并发路径与 Timer 相继处理只计一次 discarded"的断言；lease-unit 增加"过期头部候选"断言（预置 1 个已过期 Lease ⇒ take 返回 NEED_GRANT、discarded 恰 +remaining 一次、active 清空——同时锚定 O(1) 最坏扫描）；`invariants()` 增加 `discarded_tokens + Σactive.remaining + consumed == Σgranted` 的全局守恒校验与**每 Pool `#active ≤ 1`（方案 B 上界）**校验。

### 遗留问题




- **真实 OpenResty 并发验证 NOT VERIFIED**：探针 2 是 Lua 协程交错模型；真实 cosocket + ngx.sleep 注入需在 Kong Worker 内做（或用 k6 高并发打真实慢 Redis 复现堆积），关口三修复后必须用真实 E2E 复核修复效果。
- **Worker RSS（层次 2）与长稳（层次 3）NOT RUN**：需授权新增"按请求变维"的 k6 场景（现有 k6/latency.js 打固定 /echo，无法产生高基数 key）；命令草案：k6 变维 header 压 10 万 key → `docker compose exec kong1 sh -c 'grep VmRSS /proc/<worker>/status'` 前后对比。
- N3（Cluster CROSSSLOT）**未获授权（冻结轮再次确认）**：保持已确认的条件性兼容性问题记录，不改 `redis/*.lua`、`lib/redis.lua` 内嵌脚本、Redis Lua 协议；等待单独批准。
- N1/N2 的修复会改变 Redis key 形态（存量桶/Lease 全部失效一次），需你确认可接受。
- Worker RSS（层次 2）与长稳（层次 3）：NOT RUN（冻结轮保持，关口三修复后补真实验证）。

### 提交状态（2026-11-15 收尾核对）

- `bd8804d` test: add lease memory and concurrent-grant probes (gate-1 evidence)——两个探针脚本
- `4db584f` docs: remediation baseline evidence and frozen gate-2 design——本文件
- 已推送 `origin/remediation/hardening`；工作区仅剩与本整改无关的未跟踪文件 `1113.json`、`1115.json`
- 本轮收尾核对修正 3 处文档与实际的不一致：补测入口数 11→16、提交状态更新、§2 内存依据表述改为"单点实测 + 推导"

---

## 关口三：实施记录（2026-11-15，基于冻结设计 e0c3cf1）

### 改了什么

| 文件 | 内容 |
|---|---|
| `kong/plugins/rate-limit-advanced/lib/lease.lua` | ① Pool 生命周期：`active` 集合 + `last_used`（TAKE 一次赋值）+ `max_age` 毫秒快照（首次 GRANT 时取 `bucket_ttl_ms`=2×window）；诊断清单 `pool.leases` 取消，历史入计数器。② 计数器扩展：`expired/evicted/discarded_tokens`；`stats()` 输出 `outstanding/pools`。③ 过期：`created_at + max_age/1000 < ngx.now()` ⇒ EXPIRED，经唯一函数 `expire_lease_at` 摘除（state 翻转→计数→移出 active 同一非 yield 片段）；TAKE 候选逐个 O(1) 过期比较。④ 单在途 GRANT：`_inflight[pool_key]` 标志（grant 内置位/清除无 yield 间隙）；register 拒绝 ACTIVE 非空 Pool（`pool has active lease` ⇒ 生产不可达，触发按 uncertain 损失）。⑤ 容量：`MAX_POOLS=10000`（模块常量，测试可覆写）、`ensure_capacity()`（达上限先淘汰空池 ≤64，仍满 ⇒ false）、`evict_idle_pools`（只删无 ACTIVE Lease 的 Pool，零库存损失）、`timer_sweep_once`（空闲候选判定 + 过期摘除 + 删池，≤64/tick）、`start_sweep_timer`（`ngx.timer.every(60,…)`，模块级防重、pcall、exiting 检查；resty 无 timer 环境安全跳过）。⑥ `invariants()` 扩展：每 Pool `#active ≤ 1`；全局恒等式 `tokens_granted == tokens_consumed + Σactive.remaining + discarded_tokens`；租约数量闭环 `leases == closed + expired + active`。 |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | `check_lease` 在 NEED_GRANT 后插入两类降级（冻结方案 B）：`ensure_capacity()` false ⇒ `pool_cap`；`grant_in_flight(key)` true ⇒ `inflight`。两者退化为 `redis_mod.grant(conf, key, 1, …)` 直连（不登记、复用 batch=1 既有 429/Fail-close 语义、不进 Lease 账目）；日志 `pool_cap_degraded`（warn，稀有）/`inflight_degraded`（debug）。 |
| `kong/plugins/rate-limit-advanced/handler.lua` | `init_worker` 调用 `lease.start_sweep_timer()`；失败打 warn（容器实测无告警、Worker 正常注册）。 |
| `test/lease-unit.lua` | 45 断言（原 25，意图保持）：诊断表断言改为计数器闭环；"多 Lease 并存"改为顺序纪元 + busy 拒绝；新增过期（含 discarded 一次计数/单位毫秒换算）、sweep_pool、Timer（空闲删池/活跃保留/上限 64/70 池两轮）、MAX_POOLS（含"含 ACTIVE Pool 不被驱逐"）。 |
| `test/algorithm-lease-unit.lua` | 25 断言（原 17）：D 块计数器闭环改造；新增 K（pool_cap 降级直连 + 空池淘汰后恢复）、L（inflight 降级直连 + 不入账）、M（N=20 协程 burst：transport 恰 1 次、直连 19 次、`#active==1`、恒等式成立）。 |
| `test/lease-iso.lua` | lease_id 输出改从 `pool.active` 取（诊断清单取消），隔离断言不变。 |
| `test/lease-concurrent-grant-probe.lua` | 补 `redis_mod.grant` stub 计数（直连降级现为真路径）；输出增加 `direct_calls` 与 `leases<=1` 判定。 |

**冻结项核对**：MAX_POOLS=10000 ✓；max_age=2×window 毫秒快照 ✓（`created_at + max_age/1000 < ngx.now()` 秒口径）✓；60s Timer ✓；方案 B ✓；达上限不驱逐 ACTIVE Pool ✓；EXPIRED remaining 计入 discarded、不归还 Redis ✓；账目 `confirmed_granted = consumed + outstanding + discarded`、uncertain 单列不混入 ✓。**未实现项**：§1 的 `sweep_seq` 字段——由"Timer 只碰空闲 Pool、请求路径只碰当前 Pool"的不相交集合论证替代，无重复回收窗口（实现时发现该字段无作用点，属设计冗余；如需补可后加）。

### 测试命令与真实结果（全部本轮实测）

| 命令 | 结果 |
|---|---|
| `bash test/lease-unit.sh` | **PASS 45 / FAIL 0**（含过期/Timer/容量/上界/账目新用例） |
| `bash test/algorithm-lease-unit.sh` | **PASS 25 / FAIL 0**（含 K/L/M 新用例） |
| `bash test/config-isolation-unit.sh` | PASS 15 / FAIL 0 |
| `bash test/evalsha-unit.sh` | PASS 8 / FAIL 0 |
| `bash test/lease-grant-smoke.sh` | PASS 4+7 / FAIL 0 |
| `bash test/lease-isolation.sh` | PASS 7 / FAIL 0 |
| `bash test/lease-redis-matrix.sh` | PASS 50 / FAIL 0 |
| `bash test/concurrent-lease-e2e.sh`（真实 OpenResty 多 Worker） | **PASS 17 / FAIL 0 / NOT_VERIFIED 0**（GRANT=10、Σgranted=100、270 并发无堆积 ⇒ 降级路径未触发、行为与基线一致） |
| `bash test/lease-exhaustion-e2e.sh` | PASS 11 / FAIL 0 |
| `bash test/config-isolation-e2e.sh` | PASS 14 / FAIL 0 |
| `bash test/algorithm-lease-e2e.sh` | PASS 15 / FAIL 0 |
| `bash test/fault-recovery-e2e.sh` | PASS 12–14 / FAIL 0（断言数随恢复轮询次数时序浮动，两轮复测 14；非退化） |
| `bash test/handler-fault-e2e.sh` | PASS 26 / FAIL 0 |
| `bash test/lease-timeout-uncertain-e2e.sh` | PASS 22 / FAIL 0 / NOT_VERIFIED 0 |
| `bash test/script-cache-selfheal-e2e.sh` | PASS 15 / FAIL 0 |
| `bash test/worker-crash-e2e.sh` | PASS 16 / FAIL 0 |
| `docker compose exec -T kong1 resty /tmp/lease-concurrent-grant-probe.lua`（协程模型） | 修复后：burst N=100 ⇒ transport=1、direct=99、`leases=1(<=1:true)`、outstanding=9（修复前：leases=100、outstanding=900）；steady 同样 `leases≤1`；全部 identity_ok=true。**真实 OpenResty 并发验证 NOT VERIFIED（维持）** |
| `docker compose exec -T kong1 resty /tmp/lease-memory-baseline.lua` | 修复后：**600 B/pool（修复前 689，诊断清单移除后下降）**；GC 后可回收至 ~1.3MB；invariants=true；MAX_POOLS 估算更新：10000×600B ≈ **5.9 MB/Worker** |
| `docker compose exec -T kong1 kong reload` + 流量验证 | 新 Worker（init_worker 日志 handler.lua:20）正常服务，200 + 正常限流头；无 `sweep timer not started`/`timer create failed` 告警 |

### 账目 / 上界 / 并发验证证据（口径区分）

- **账目恒等式**：lease-unit（accounting-identity、expire-discarded-once、expire-invariants、capacity-invariants）+ algorithm-lease-unit（M-ledger-identity、L-direct-out-of-ledger）+ 探针全部场景 identity_ok=true + invariants() 全局校验。uncertain 不入恒等式：既有 grant-uncertain-no-retry-no-register 断言保留且 PASS。
- **active 上界**：register busy 拒绝（multi-lease-busy-reject）+ invariants() `#active ≤ 1` 校验 + M 用例 burst N=20 断言 `st.active == 1` + 探针 burst N=100 `leases=1(<=1:true)`。
- **并发 GRANT（真实环境 vs 模型）**：真实 OpenResty 证据 = concurrent-lease-e2e.sh（270 并发，GRANT=10 无堆积，降级路径未触发——与基线一致）+ worker-crash/timeout 等 E2E 全绿；协程模型证据 = 探针与 M 用例（量化降级效果：库存 900→9）。**后者不得写成真实并发验证（NOT VERIFIED 维持）**。

### 对外行为影响

- 正常路径（无并发堆积、Pool 未达上限）：与基线**逐字节一致**（concurrent-lease-e2e 等 10 个 E2E 全绿即证据）；429/Retry-After/X-RateLimit-*/503 Fail-close/fault_tolerant/batch=1/多规则全或无语义未动。
- 新增行为 1：同 Pool 在途 GRANT 期间的并发 miss ⇒ batch=1 直连放行（授权仍由 Redis 桶决定；空桶仍 429；Redis 故障仍 503/fail-open）。吞吐：热路径不变；直连路径每请求一次 Redis（与 batch=1 同成本）。
- 新增行为 2：MAX_POOLS 达上限且无可淘汰空池 ⇒ 同上直连（罕见，仅高基数攻击场景）；空池淘汰零库存损失，不产生 429/503。
- 新增行为 3：过期 Lease 在 TAKE 时被丢弃（discarded 计数）——慢速热 Pool 上不再跨桶纪元消费；时钟回拨时库存存活略久（§3 既有定性，方向保守）。
- 语义风险点（已评估）：register busy 拒绝在"上界被破坏"时把请求归入 uncertain ⇒ Fail-close（保守方向，不会伪装放行）。

### 遗留问题 / 风险

- **真实 OpenResty 并发验证 NOT VERIFIED（维持）**：协程模型与真实 E2E 双证据已最强化，但"降级路径在真实 cosocket 交错的触发率"无现场数据（concurrent-lease-e2e 场景未触发）。可用 CLIENT PAUSE + 并发压测的专项 E2E 复核（待授权）。
- **Worker RSS（层次 2）/ 长稳（层次 3）NOT RUN（维持）**；修复后 Lua 堆实测 600 B/pool。
- **Timer 周期触发的现场观测 NOT VERIFIED**：注册无错 + 回调体逻辑经 timer_sweep_once 单测覆盖；60s 现场触发（含 worker exiting 分支）未直接观测。
- `sweep_seq` 未实现（见上，设计冗余，无行为影响）。
- N3（Cluster CROSSSLOT）**维持未授权**；N1/N2（维度值碰撞）未动（key 形态变更需确认）；N4–N8 维持记录。
- 探针 steady 场景 grant_calls=8/direct=29：直连与 Lease 混合下的总账（lease 账 + 直连批）跨路径对账仍无手段（V1 无 Redis 对账接口），维持"允许损失、方向保守"表述。

### 关口三审查修复：容量边界（inflight Pool 回收排除 + 在途 GRANT 占位）

**改了什么 / 为什么**：审查发现 `evict_idle_pools()` 与 `timer_sweep_once()` 只判 `active` 空，不排除在途 GRANT 的 Pool——GRANT yield 期间 Pool 被回收、返回后 `register()` 重建 ⇒ `_pool_count` 超 MAX_POOLS。修复（`lib/lease.lua`）：① 两处回收逻辑跳过 `_inflight[key]==true` 的 Pool；② 推演发现同族问题——跨 Pool 并发 GRANT 各自通过 ensure_capacity 后才 register，同样超上限 ⇒ `ensure_capacity()` 改为在途 GRANT **占用池位**口径：`_pool_count + inflight_count() ≥ MAX` 即视为达容量（不改变"不驱逐 ACTIVE Pool / 不 429 不 503"冻结行为，仅使降级判定覆盖在途占位）；③ `invariants()` 新增容量上限不变量 `_pool_count ≤ MAX_POOLS`（测试直改 MAX 的人工态除外——既有 capacity 用例先恢复 MAX 再断言，无需改动）。

**测试命令与真实结果**（全部实测）：
- `bash test/lease-unit.sh` → **PASS 50 / FAIL 0**（新增 timer-skip-inflight、timer-evict-after-inflight-clear、evict-skip-inflight、evict-after-inflight-clear 4 用例）
- `bash test/algorithm-lease-unit.sh` → **PASS 32 / FAIL 0**（新增 N 用例：确定性协程——A 的 GRANT yield 期间 B 触发容量回收，断言 A 的 Pool 对象不被回收/重建（同 table 引用）、空池 C 被正常淘汰、B 降级直连、恢复后 `pool_count ≤ MAX_POOLS`、恒等式成立）
- `bash test/concurrent-lease-e2e.sh` ×3 → **PASS 18 / FAIL 0 / NOT_VERIFIED 0** ×3。断言适配（方案 B 设计行为，非降级）：原 `allowed == Σgranted(Lease)` 在直连降级触发时不再成立；改为 **授权总账 = Lease Σgranted + 直连批 == limit=100**，直连批以 Redis `INFO commandstats` 的 EVALSHA 增量实证（增量 − Lease 记录数 − denied-GRANT 数）。第 1 轮真实环境实测：Σgranted=96 + 直连=4 = 放行 100，账目精确闭合——**降级路径在真实 OpenResty 环境触发并被账目闭环验证**（协程模型的量化结论仍维持 NOT VERIFIED 口径不变）。
- `docker compose exec -T kong1 resty /tmp/lease-memory-baseline.lua` → PASS（invariants 含新容量不变量；探针以 `lease.MAX_POOLS = N` 匹配直建规模）
- `bash test/algorithm-lease-e2e.sh` PASS 15/0；`bash test/worker-crash-e2e.sh` PASS 16/0；`bash test/lease-exhaustion-e2e.sh` PASS 11/0；`bash test/config-isolation-unit.sh` PASS 15/0；`bash test/lease-grant-smoke.sh` PASS 7/0；`bash test/evalsha-unit.sh` PASS 8/0。

**对外行为影响**：仅容量判定口径收紧（在途 GRANT 占位）——正常流量（Pool 数 ≪ 10000）行为逐字节不变；高基数攻击场景下降级判定更保守（在途窗口内提前降级直连），仍不 429/不 503。

**遗留问题**：
- `config-isolation-e2e.sh` 存在**与本修复无关的既有偶发**（"B 桶键 ≠ A 桶键"在配置传播时序下偶现同指纹；历史报告 PHASE8_B 已记录同类偶发）。本轮 5 轮：3×14/0、2×13/1（偶发轮），复跑即恢复全绿；未改动该脚本。
- 直连批的 Redis 侧计数仅为本 E2E 的 commandstats 推导（delta − records − denied）；常规运行期无该对账口径（维持 V1 无对账接口的表述）。

### 关口三复审修复：容量计算去重（在途 GRANT 仅对新 Pool Key 占位）

**改了什么 / 为什么**：复审发现 `ensure_capacity()` 用 `_pool_count + inflight_count()` 判容量，但已存在于 `_pools` 的 Pool 的在途 GRANT 被重复计入（register 会复用原池，不新建）⇒ 不必要的容量降级。修复（`lib/lease.lua`）：`inflight_count()` 只统计 `_pools[key] == nil` 的在途 key（register 将新建池的才占位）。两处回收的 inflight 跳过保护保持不变；`invariants()` 的 `pool_count ≤ MAX_POOLS` 不变量保持不变。

**测试命令与真实结果**（全部实测）：
- `bash test/algorithm-lease-unit.sh` → **PASS 36 / FAIL 0**。N 用例按修复语义更新：A 在**已有 Pool** 上 GRANT yield 期间，B 应使用剩余最后一个池位正常 GRANT（`calls.grant==0`、无降级日志、B 池创建、count=2=MAX），A 恢复后 register 复用原 Pool（同 table 引用），总数 ≤ MAX、恒等式成立（复审要求 3 的确定性测试）。新增 O 用例：两个**新 Pool Key** 并发 GRANT 占用两个池位，第三个新 Key 正确降级直连（`calls.grant==1`、warn=1），两笔在途登记后 `pool_count == 2 ≤ MAX`（验证要求 4）。
- `bash test/lease-unit.sh` → PASS 50 / FAIL 0；内存探针 PASS（含容量不变量）；并发探针 burst N=100：`leases=1`、库存 9（不变量保持）。
- 全量回归 14 入口：matrix 50/0、concurrent-lease-e2e **18/0**、exhaustion 11/0、algorithm-e2e 15/0、fault-recovery 13/0、handler-fault 26/0、timeout-uncertain 22/0、selfheal 15/0、worker-crash 16/0、isolation 7/0、smoke 7/0、evalsha 8/0、config-isolation-unit 15/0。
- `config-isolation-e2e`：回归中发现偶发率升高，定位为**既有测试非确定性缺陷**——B_BKT 采样用无序 `SCAN | head -1`，A/B 两桶键共存时可能采到 A 的键（同轮 "B pool_key ≠ A pool_key" PASS 证明 B 记录正确）。最小修复（显式排除 A_BKT 后取样，断言意图不变），修复后 **4 连 14/0**。非生产代码问题、与容量修复无关。

**对外行为影响**：消除误降级——已在途的既有 Pool 不再被重复计入容量 ⇒ 高基数下"最后一个池位"可正常使用；新 Pool 在途仍占位 ⇒ `_pool_count ≤ MAX_POOLS` 仍严格成立。冻结行为（不驱逐 ACTIVE Pool、不 429/不 503、方案 B）不变。

---

## 关口四：Key 统一构造（任务 A，基于 ce78bd9）

### 任务 A：Key 统一构造（维度碰撞 + CROSSSLOT，同次实现）

**改了什么 / 为什么**：
- 新增 `lib/keys.lua`：`encode_value(s)`——维度值仅转义 4 个歧义字节（`:`→`%3A`、`%`→`%25`、`{`→`%7B`、`}`→`%7D`；其余字节含非 ASCII 原样，Redis key 二进制安全；快路径无歧义字节时原样返回，热路径零额外开销）；`build_lease_key(bucket_key, lease_id)`——桶键后追加 `:lease:<lease_id>`，与桶键共用同一 hash tag ⇒ Cluster 同 slot（消除 CROSSSLOT 的 key 层根因）。lease_id 输入规范：非空且不得含 `{`/`}`/`%`（含则拒绝 → 既有故障分支 Fail-close，零写入；该校验属输入规范，同输入规范下的 lease_id 分段 `:` 允许原样）。
- `lib/algorithm.lua`：`build_key`/`build_group_keys` 的维度值经 `encode_value`；桶键构造**不搬移**（沿用 `build_key`/`build_group_keys`，避免无关重构）；策略指纹**不变**（指纹输入不含维度值/编码）。
- `lib/redis.lua`：`grant_lease()` 的 lkey 改由 `build_lease_key` 构造（调用点代码；内嵌脚本字符串零改动）。
- **KEYS 顺序核对（GRANT vs RETURN）**：GRANT_LEASE = `KEYS[1]桶键 / KEYS[2]Lease 键`（`redis/grant_lease.lua:19-20,34-35`）；RETURN_LEASE = `KEYS[1]Lease 键 / KEYS[2]桶键`（`redis/return_lease.lua:11-12,24-25`）——**两条路径 KEYS 顺序相反**，构造规则统一为 `build_lease_key(桶键, lease_id)`，传参按各自脚本 KEYS 顺序。本关口不改任何 Lua 脚本（含 `redis/*.lua` 与 `lib/redis.lua` 内嵌脚本及其注释）；脚本头部注释中的旧 key 格式描述已过时，属脚本冻结范围待后续协议关口处理（记录于遗留）。
- 测试同步（同次提交）：9 个 E2E 的 SCAN 模式 `'kong:rl:lease:*'` → `'kong:rl:*:lease:*'`（worker-crash、algorithm-lease-e2e、concurrent、config-isolation、fault-recovery、handler-fault、lease-exhaustion、lease-timeout-uncertain）；`lease-redis-matrix.sh` 96 处字面量 `kong:rl:lease:<id>` → `kong:rl:{p3g:m}:lease:<id>`；`lease-grant-smoke.lua` 的 keys 模式与 lkey 构造改为桶键派生；`config-isolation-unit.lua` 新增 8 项 key 断言（CRC16-XMODEM 已知向量 0x31C3 自校验、`:{}%` 转义、同输入稳定、多维不碰撞、hash tag 结构 `{}` 仅在骨架边界、Lease/桶键 slot 一致（等价算法）、lease_id 输入规范）；`concurrent-lease-e2e.sh` 的 tokens 终态采样排除 `:lease:` 键并补 SIGPIPE/混合期两条教训修复（见下）。
- `docs/architecture.md` §5 键格式行同步（维度编码 + Lease 键同 tag + 旧格式废弃）。

**兼容性（按审查要求展开，含修正 2 的窗口拆分）**：
1. **滚动升级并存（不可简单表述为"一次性额外放行"）**：新旧版本 Worker 同时运行期间，两套 key 各自成账——同一逻辑维度实例同时占用**旧桶（存量水平）与新桶（满血初始配额）**，实际放行上限 = 两者之和 ⇒ **总放行可超单版本配额**（最坏 2×）。新 Key 首次使用即重新获得初始满配额，且每个新维度实例（新 ip/header/path 值）都如此。
   **两类 TTL 的影响必须分开（修正 2）**：
   - **旧桶 TTL（2×window）**：决定**旧桶限流授权状态（tokens/ts）何时消失**——即放行上限叠加窗口的收敛时间；窗口内新旧桶并存、总放行可超单版本配额，窗口过后旧桶键自然过期、只剩新桶记账。
   - **旧 Lease 元数据 1h TTL**：**只**决定元数据记录（对账/取证用）何时被清理；与库存归还无关（V1 无 RETURN），**不代表限流授权状态收敛**——授权状态由桶键承载，不受该 TTL 影响。
2. 旧 key 不再复用；指纹不变（同策略新旧指纹段相同，仅值编码不同 ⇒ 旧桶不可被新代码命中）。
3. 旧格式 Lease 记录由 1h TTL 自然消失；新 SCAN 模式不匹配旧格式（测试环境为全新 key 空间，无混合）。

**测试命令与真实结果**（全部实测）：
- 单元：`config-isolation-unit.sh` **24/0**（含 8 项新 key 断言）；`lease-unit.sh` 50/0；`algorithm-lease-unit.sh` 36/0；`evalsha-unit.sh` 8/0。
- Redis 裸跑：`lease-redis-matrix.sh` **50/0**（新格式字面量全量更新；GRANT/RETURN 全矩阵经新键格式）。
- 真 Redis 链路：`lease-grant-smoke.sh` 4+7/0（新格式记录取证）。
- E2E（真实 OpenResty 多 Worker，新 key 格式在产）：concurrent-lease **19/0 ×3**（其中 Σgranted=92+8、93+7、97+3、98+2 均精确闭合 100；直连批 2~9 随时序浮动）；exhaustion 11/0；config-isolation 14/0；algorithm-e2e 15/0；fault-recovery 12–14/0（轮询浮动）；handler-fault 26/0；timeout-uncertain 22/0/0；selfheal 15/0；worker-crash 16/0；isolation 7/0。
- 本轮测试脚本附带修复（同提交，非范围外）：① `concurrent-lease-e2e.sh` 前置增加"reload 混合期收敛等待"（教训：`kong reload` 后旧 Worker 短暂共存，旧格式记录不被新 SCAN 计入而 EVALSHA 计入 ⇒ 账目伪差值）；② 断言 8 的 `SCAN|head` SIGPIPE 教训修复（pipefail 下静默中断）+ tokens 采样排除 `:lease:` 键（新 Lease 键与桶键共享前缀，否则断言空洞通过，本轮实测 tokens=0.0011881189776839 有值）。

**NOT VERIFIED（如实声明）**：真实 Redis Cluster 环境下的 GRANT_LEASE/RETURN_LEASE/EVALSHA/NOSCRIPT 行为未验证（本环境 standalone，`CLUSTER KEYSLOT` 返回 cluster support disabled）；slot 一致性由测试侧 CRC16-XMODEM 等价算法验证。**解决 CROSSSLOT 不等于完整支持 Redis Cluster**——Cluster 部署仍需独立的按节点脚本缓存、重定向等验证（维持既有 Deferred 记录）。

**遗留问题**：① `redis/grant_lease.lua:20`、`redis/return_lease.lua:11` 及 `lib/redis.lua` 内嵌脚本头注释中的旧 key 格式描述未更新（脚本文件本关口冻结不动，待协议关口）；② N1（维度值 256 截断碰撞）不在本任务范围，维持记录；③ 全量 percent 编码（非 ASCII 字节原样）为本关决策，若未来要求 key 全 ASCII 可再评估（会再次全量换 key）。

### 任务 A 审查修正（2026-11-15，二处，不扩范围）

**修正 1：wait_stable() 可靠性**。原实现 `pgrep -f 'nginx: worker process'` 会误匹配执行命令的 shell（其 cmdline 含该模式串），且"进程数连续两次相同"无法证明旧 Worker 退出（新旧各 2 个时计数恒为 4）。重写（test/concurrent-lease-e2e.sh）：
- 枚举：`/proc/[0-9]*/cmdline` **前缀**精确匹配 `"nginx: worker process "`（shell 自身 cmdline 以 `sh -c` 开头 ⇒ 不匹配；head/tr 子进程同理）⇒ 输出 Worker PID 集合。
- 代际判定：配置下发**前**抓取旧代 PID 集合（POST /config 可能触发 reload）；收敛 = 代际单一——无 reload（当前集合 == 旧代集合）或旧代 PID 全部退出（两集合无交集）；任一不可证 ⇒ 30s 超时以"无法证明旧 Worker 全部退出"失败退出，不降低账目断言证据强度。
- 函数定义前移至 PID 快照之前（原顺序存在使用先于定义的缺陷，本轮已修）。
- 结论措辞同步收敛为"Worker 代际单一（PID 集合实证：无 reload 同集合，或旧代 PID 全部退出）"，不宣称超出实证的内容。
**验证**：`bash -n` 语法通过；`bash test/concurrent-lease-e2e.sh` ×3 → **EXIT=0、PASS 20 / FAIL 0 / NOT_VERIFIED 0 ×3**（第 2/3 轮总账 90+10=100、97+3=100 精确闭合；既有断言零改动，PASS 数 19→20 系代际判定自身的 ok() 新增 1 项）。

**修正 2：兼容性窗口拆分**。原表述"窗口 = max(旧桶 TTL, 旧 Lease 记录 1h)"混用了两类 TTL：旧 Lease 元数据 1h TTL 只决定**对账记录清理时间**，与库存归还无关（V1 无 RETURN）、不代表限流授权状态收敛；授权状态由桶键承载。已改为两条独立描述：旧桶 TTL（2×window）= 放行上限叠加窗口的收敛时间；旧 Lease 1h TTL = 元数据记录可见窗口。仅文档改动。

### 任务 A 复审收尾修正（2026-11-15，二处，仅 test/concurrent-lease-e2e.sh）

**改了什么 / 为什么**：
1. **旧代 PID 快照有效性核验（新增，配置下发前执行）**。原实现抓取 `PIDS_K1/K2/K3` 后直接进入 `wait_stable()` → `single_generation()`：空快照会把"旧代为空"误判为"旧代全部退出"（`single_generation` 对空 `$1` 返回 0），削弱账目断言证据强度。修正：前置检查循环记录各节点 Worker 数（`W_K1/K2/K3`），快照抓取后逐节点核验——**非空、`wc -w` ≥2、与前置核验数量一致**，三者任一不满足即 `bad` + `exit 1` 直接失败，不允许空集合进入代际判定；核验通过输出 `ok "快照有效：…"`（每节点 1 项 PASS）。
2. **删除重复的"配置下发"ok()**。配置下发成功后连续两次输出同一 ok()（无新增信息），导致 PASS 计数虚高 1。删除其一，保持 PASS 计数准确。

**测试命令与真实结果**（本轮实测）：
- `bash -n test/concurrent-lease-e2e.sh` → 语法通过。
- `bash test/concurrent-lease-e2e.sh` ×2 → **EXIT=0、PASS 22 / FAIL 0 / NOT_VERIFIED 0 ×2**（第 1 轮 Σgranted=92+直连 8=100、429=300、min remaining=0；第 2 轮 Σgranted=95+直连 5=100、429=300、min remaining=0）。PASS 数 20→22 系快照有效性核验新增 3 项 ok() 减去重复 ok() 1 项（20+3−1=22）。

**对外行为影响**：无（测试脚本自身；生产代码、冻结设计、既有断言零改动）。

**遗留问题**：无新增；既有遗留维持（脚本头注释旧 key 格式描述、N1、真实 Cluster 验证 Deferred）。

---

## 关口四：任务 B——Lease 元数据成本审计（基于 a2ba601，2026-11-15，只读）

**改了什么**：无生产代码/脚本/Schema 改动。仅新增本节（独立文档提交）。测试环境写入（合成记录）已全部 UNLINK 清理，DBSIZE 恢复 137、used_memory 恢复 1.71M。

### 审计结论 1：Lease Hash 字段与单条记录（实测）

- **字段（5 个，HLEN 实测=5）**：`lease_id`（host:worker:seq:hex，26~27B）、`pool_key`（桶键原文，43B）、`granted`（数值字符串）、`status`（`OPEN`）、`created_at`（服务端 Redis TIME 浮点字符串，16B）。RETURN 后追加 `return_requested`（6 字段）。全部为 hash 字符串字段（`redis.lua:274-280`，双源 `redis/grant_lease.lua:131-137` 同源同构）。
- **TTL（实测）**：PTTL=3,592,908ms（≈59.9min）⇒ 1h 生效。`LEASE_TTL_MS=3600000` 为固定常量（`algorithm.lua:21`，非 Schema 字段，无配置覆盖），脚本内 `PEXPIRE lkey` 设置（`redis.lua:280`）。
- **过期行为（冻结口径重申）**：TTL 到期整键删除——**仅元数据消失**；无令牌恢复、无库存归还（V1 无 RETURN；不把元数据过期描述为库存归还）。RETURNED 记录保留至**原 TTL**（不重设，`redis.lua:398`）＝幂等保护窗口 ≤1h。
- **单键内存（实测）**：真实记录（键 74B）MEMORY USAGE=280B；等长合成键（75B）SAMPLES 0=280B；短键（48B）@1M 规模=264B ⇒ 键长 +27B payload ≈ +16B 内存。

### 审计结论 2：GRANT_LEASE 写命令与往返（口径区分，不混为一谈）

| 口径 | granted≥1（建记录） | granted=0（不足） |
|---|---|---|
| 脚本内写命令 | **4 条**（桶 HSET+PEXPIRE，记录 HSET+PEXPIRE） | 2 条（仅桶；不建记录） |
| 其中记录本身 | 2 条（HSET 5 字段 + PEXPIRE） | 0 |
| 网络往返 | **1 次**（EVALSHA；keepalive 连接复用；脚本缓存后无 LOAD） | 1 次 |

- 每 Worker 每脚本首用 +1 次 SCRIPT LOAD 往返；运行中 NOSCRIPT ⇒ +1 LOAD +1 EVALSHA 重试恰一次（冻结语义不变，`redis.lua:444-463`）。佐证：concurrent-lease-e2e 关口四 commandstats 口径实测（400 请求 / EVALSHA 增量 318，含 denied-GRANT 与直连批）。

### 审计结论 3：RETURN_LEASE（代码核实；V1 无生产调用点）

- `lib/redis.lua` 无 `_M.return_lease` 包装函数；脚本仅注册（`redis.lua:422`），生产代码零调用——与关口一线索 e 结论一致；唯一执行入口是测试（`lease-redis-matrix.sh` 裸 --eval）。
- **写命令**：幂等提交点 `HSET lkey status=RETURNED + return_requested`（1 条）→ requested>0 时 + 桶 HSET+PEXPIRE（共 3 条）；TTL **不重设**。
- **幂等（以脚本实际逻辑为准）**：`ALREADY_RETURNED`（status=RETURNED 且 return_requested==requested，零写）；`RETURN_CONFLICT`（同 status 不同 requested，零写）；`POOL_MISMATCH`/`LEASE_NOT_FOUND` 等校验失败均零写。

### 审计结论 4：内存成本量化（1万 / 10万 / 100万）

**测试环境**：docker compose redis（Redis 7.4.12，standalone，无持久化、无 maxmemory/noeviction），宿主机 15GB；合成记录与真实记录同构（5 字段等长值、PEXPIRE 3600000）；`redis-cli --pipe` 灌入（1M 条 10.2s，errors=0）。

| 规模 | used_memory 增量（实测） | 平均 B/条（实测，48B 键） | 总内存（含键长修正，估算） |
|---|---|---|---|
| 1 万 | 3,162,736B（3.16MB） | 316 | ≈3.3–3.5MB |
| 10 万 | +27,755,024B ⇒ 累计≈30.9MB | 308（边际） | ≈32–34MB |
| 100 万 | +288,280,064B；used_memory_human=**306.08MB** | 320（边际） | ≈**330–350MB** |

- **口径说明**：批量平均（308~320B/条）= 单键自内存 + keyspace dict 与 expire 表均摊开销；单键自内存（实测 264B@48B 键 / 280B@74B 键）不含 keyspace 开销——四个口径（写命令数 / 往返次数 / 单键内存 / 总内存）互不相代。
- **估算依据（推导）**：实测基线（48B 键）+ 键长修正 +16~30B（真实键 70~80B：namespace 可变、lease_id seq 位数浮动）。
- **误差来源**：①键长与 lease_id 长度随部署/时序浮动（主项，±10%）；②dict rehash 瞬态；③fragmentation（1M 规模实测 1.03，小规模噪声大 2.45）；④分配器/Redis 版本差异。
- **NOT VERIFIED**：Redis Cluster 下 per-record 结构相同但每节点 dict/expiry 独立的开销、主从复制流量、TTL 惰性/定期删除的长稳开销——均未验证。

**对外行为影响**：无（纯审计；不接入自动 RETURN，不改 Lease 生命周期、TTL、键与脚本）。

**遗留问题**：① Cluster 内存/复制流量未验证（维持既有 Deferred 记录）；② 无新增待办；不 propose 任何优化（未经批准不做）。

---

## 关口四最终验收（基于 14297da，2026-11-15，只读审计）

**结论：验收通过（PASS）。无阻断问题。**

### 1. 实施与审计记录完整性核对

- **任务 A 记录**：主体（改了什么/为什么/兼容性含窗口拆分/测试命令与真实结果/NOT VERIFIED/遗留）+ 审查修正（修正 1 wait_stable 重写、修正 2 TTL 窗口拆分）+ 复审收尾修正（PID 快照有效性核验、重复 ok() 删除）——三段完整，均含实测证据与 PASS 计数口径。
- **任务 B 记录**：字段/TTL/单键内存实测、写命令与 RTT 口径区分、RETURN_LEASE 代码核实、1万/10万/100万 内存量化（实测+推导+估算分层标注）、NOT VERIFIED 与误差来源——完整。

### 2. 冻结决策遵守核对（git diff ce78bd9..14297da 全量核对）

- **禁改文件零改动**：`redis/*.lua`、`schema.lua`、`openspec/`、`bench/`、`docs/reports/` 在本关口范围内 diff 文件数=0。
- **内嵌脚本未动**：`lib/redis.lua` 本关口 diff 仅两处 hunk（`require keys_mod` + `_M.grant_lease` 调用侧 lkey 构造），GRANT_LEASE/RETURN_LEASE 脚本字符串字面量零改动（双源 `redis/grant_lease.lua`、`redis/return_lease.lua` 未触碰）。
- **语义不变项核对**：batch=1 逐请求授权、rules 全或无、429+Retry-After、X-RateLimit-* 头、Fail-close 503、fault_tolerant 语义、GRANT 不确定不重试不登记、NOSCRIPT 重试恰一次——本关口 diff 未触及上述路径（改动仅限：`lib/keys.lua` 新增、`algorithm.lua` 维度值经 encode_value、`redis.lua` 调用侧 lkey、测试同步、文档）。
- **未扩大范围**：RETURN 接入、N1、自动生命周期、Schema 字段——均未实施（任务 B 明确不 propose 优化）。

### 3. 测试结果汇总（区分 PASS / FAIL / NOT RUN / NOT VERIFIED）

**最终 HEAD（14297da）本轮全量复测——实测，全部 PASS、0 FAIL**（16 个测试入口）：

| 类别 | 脚本 | 结果 |
|---|---|---|
| 单元 | config-isolation-unit（含 8 项 key 断言） | 24/0 |
| 单元 | lease-unit | 50/0 |
| 单元 | algorithm-lease-unit | 36/0 |
| 单元 | evalsha-unit | 8/0 |
| Redis 裸跑 | lease-redis-matrix | 50/0 |
| 冒烟 | lease-grant-smoke | 4+7/0 |
| E2E | concurrent-lease-e2e | 22/0 |
| E2E | algorithm-lease-e2e | 15/0 |
| E2E | lease-exhaustion-e2e | 11/0 |
| E2E | config-isolation-e2e | 14/0 |
| E2E | lease-timeout-uncertain-e2e | 22/0/0 |
| E2E | fault-recovery-e2e | 14/0 |
| E2E | handler-fault-e2e | 26/0 |
| E2E | script-cache-selfheal-e2e | 15/0 |
| E2E | worker-crash-e2e | 16/0 |
| E2E | lease-isolation | 7/0 |

合计 **PASS=341 / FAIL=0 / NOT RUN=0**。NOT VERIFIED（非本轮测试项，见 §4）。

### 4. 未解决风险与 Deferred（哪些不影响 V1）

**不影响 V1（standalone 部署、既有行为契约下）**：
- Redis Cluster 完整支持（N3 键层 CROSSSLOT 已修，但按节点脚本缓存/重定向/Cluster 内存与复制流量未验证）——standalone 部署不受影响，Cluster 部署前须独立验证（Deferred）。
- Worker RSS / 长稳 / 真实 OpenResty 并发验证（关口二冻结保留）——证据完整性缺口，非正确性阻断；账目断言已有 E2E 实测背书。
- 脚本头注释旧 key 格式描述过时（`redis/grant_lease.lua:20`、`redis/return_lease.lua:11`）——文档性，行为无影响，待协议关口。
- 任务 B 内存估算误差 ±10%——估算标注完整，非风险项。
- Phase 5 生命周期整体 DEFERRED（项目既有决策，V1 范围外）。

**升级期风险（一次性，不影响稳态）**：
- 键迁移兼容窗口：滚动升级新旧桶并存 ⇒ 总放行可超单版本配额（2×window TTL 收敛）；新维度实例重新获得初始配额——已在任务 A 兼容性一节按审查要求拆分描述。

**待后续关口决策（非本关口阻断）**：
- N1（维度值 256 截断碰撞）：维持记录，未经批准不实施。
- 全量 percent 编码决策：非 ASCII 字节原样为本关决策，若未来要求 key 全 ASCII 需再评估（会再次全量换 key）。

### 5. Git 状态核对（实测）

- 分支 `remediation/hardening`；HEAD=14297da5b60719bb63c07326b50eb0b34a734c25；与 `origin/remediation/hardening` 同步（rev-list 0/0）。
- 关口四提交链（ce78bd9 → 14297da，4 commits）：`665fa8d`（任务 A 实现）→ `a43a20b`（审查修正 1+2）→ `a2ba601`（复审收尾修正）→ `14297da`（任务 B 审计）——每步独立、范围递进、无混提。
- 工作区：已跟踪文件零修改；3 个未跟踪会话导出文件（`1113.json`/`1115.json`/`1115-2.json`）非仓库内容、未提交、非本关口产物。

**对外行为影响**：无（纯验收审计；键格式变更行为影响已在任务 A 兼容性一节记录）。

**遗留问题**：§4 清单即遗留全集；无新增阻断。

---

## 关口五：文档与算法模型对齐（基于 80865dc，2026-11-15，仅文档）

**改了什么 / 为什么**：以最终代码实现为准，对齐四份文档；每份单独提交，openspec/、docs/reports/、
bench/、生产代码、Lua、Schema 零改动。

| 提交 | 文件 | 对齐要点 |
|---|---|---|
| `e265f16` | docs/design.md | 清除全部 ⟨TODO⟩；删除 shared dict 库存描述（§2 总览图/时序图、§5 fast path、§4.8、§7 故障矩阵行）；§4.9 新增 Lease 生命周期与本地 Pool 模型（MAX_POOLS=10000/Worker、max_age=2×window、EXPIRED/EVICTED/discarded、60s Timer、方案 B 单在途、invariants() 恒等式）；§12 更新 key 结构（维度值编码 + Lease 键同 hash tag）+ Lease 元数据模型（5 字段、TTL 1h、不等于库存归还）+ Cluster 支持边界（键层已修/行为未验证）；§7 故障矩阵补 Pool 压力降级与元数据 TTL 行；§8 实验矩阵标 Historical 并指向 Phase 7 实测；§9 取舍表更新（Lease 预授权/维度值编码）；§11 生产差距更新（本地 Pool 回收已实现、RETURN 仍 Deferred、时钟结论）；【Historical】/【Current V1】/【Deferred】标记约定 |
| `352fe1b` | README.md | 精度语义改为前提化表述（放行 ≤ 已确认扣减的推导；少发多来源如实列出；超发仅故障回滚窗口）；补三类风险（指纹并存/主从回滚/本地消费突发，含 burst_max 推导上界）；§6 补 DB-less 逐节点下发并存风险与规避建议；§8 性能口径补齐（81.8%、Kong CPU −23%、Redis CPU −73% 全部仅引 Phase 7）；修正陈旧断言数（lease-unit 25→50、algorithm-lease-unit 17→36、concurrent-lease-e2e 17→22，关口四验收实测值）；对比表"只少发不超发"改为前提化表述 |
| `f6bf343` | docs/architecture.md | §1 重画架构图（3 节点 × 2 Worker、每 Worker 独立 Lease 池、三条请求路径、Redis 故障 Fail-close，明确不跨 Worker 共享库存）；核心不变量改为前提化表述；§2 补两条降级直连路径（pool_cap/inflight）；§3 决策流程图补降级判定分支；§7 生命周期图更新（EXPIRED/EVICTED/discarded、Timer、方案 B、O(1) 上界）；§8 账目改为冻结恒等式 confirmed_granted = consumed + outstanding + discarded（uncertain 单列）；§12 补 81.8%；§13 Deferred 表更新（本地 Pool 回收已实现、Cluster 键层已修） |
| `9d4e7ce` | docs/design.md | 取舍表一致性措辞同步（推导上界/估算/NOT VERIFIED 分层） |

### 误差模型重推导（核心交付）

变量统一：N=副本数、W=每副本 Worker 数、W_total=N×W、k=batch、B=桶容量（burst>0?burst:limit）。
统计对象=单逻辑 key 的授权库存；作用域与前提逐项声明：

- **瞬时滞留 ≤ W_total × k：推导上界**（前提：①每 Worker 每 Pool 任意时刻 ≤1 个 active Lease——
  关口三不变量、invariants() 断言守护；②granted ≤ k；③V1 无 RETURN）。**不是 N×W×k 的旧公式**：
  旧模型按"每节点一份库存"，V1 Lease 为 Worker 私有，界随 W_total 缩放。
- **每窗口累计少发无封闭严格上界**：discarded（单次 ≤k，代际数取决于流量形态）、Worker 崩溃 lost
  （单次 ≤k）、GRANT uncertain（**无封闭上界**：不重试不登记是冻结语义，事件数随故障率）——
  全部标注"估算"，长稳分布 NOT VERIFIED。
- 利用率表按 W_total=6 重算（1000/k=20 → 88%；100/k=2 → 88%；10000/k=50 → 97%），标注估算口径。
- 突发放大 burst_max = B + W_total·k（推导上界）；`resolve_batch` clamp(limit/50,1,50) 与代码一致，
  "2%" 语义明确为**单 Worker** 滞留。

### 一致性检查（与实际代码、冻结设计）

- resolve_batch 公式、MAX_POOLS、max_age=2×window、LEASE_TTL_MS=3600000、discarded 单次计数、
  方案 B 直连降级、键编码（%3A/%7B/%7D/%25）、256 截断（N1 维持记录）、Phase 7 性能数字
  （9.99:1 / 81.8% / −23% / −73% / p99 NOT VERIFIED / 7848=3.1%）——逐一与代码/报告核对一致。
- README 两处 "shared dict" 均为"不依赖"否定表述（准确）；design.md/architecture.md 无 shared-dict
  库存残留；三文档间交叉引用（§ 编号、报告路径）核对。

### 测试命令与真实结果

- 本关为文档对齐，无生产代码改动，未新增/重跑测试；测试状态沿用关口四最终验收
  （16 入口 PASS=341 / FAIL=0 / NOT RUN=0，14297da 实测；本关基线 80865dc 与其零代码差异）。
- 范围验证（实测）：`git diff 80865dc..HEAD --stat` 仅 4 个文档文件；
  `git diff 80865dc..HEAD -- redis/ .../schema.lua openspec/ bench/ docs/reports/` 文件数=0。
- 静态检查（实测）：`grep TODO docs/design.md`=0；mermaid 图标签配对人工核对通过；
  **mermaid 渲染效果未验证**（环境无渲染工具，标注 NOT VERIFIED）。

### 对外行为影响

无（纯文档；行为契约表述从无条件"不超发"改为前提化精度声明，属于描述对齐，非行为变更）。

### 遗留风险

① N1（256 截断跨维度碰撞）维持记录未修；② mermaid 渲染未验证（人工核对）；③ W_total×k 上界
的前提依赖 invariants() 断言守护而非协议保证（已在文中如实标注）；④ 长稳少发分布 NOT VERIFIED
维持。无新增阻断。

---

## 关口五复审修正（基于 9d4e7ce→，2026-11-15，定点四项，不扩范围）

**改了什么 / 为什么**（每份文档单独提交；生产代码/Lua/Schema/openspec/docs/reports/bench 零改动）：

| 提交 | 文件 | 修正 |
|---|---|---|
| `5cfbb1d` | README.md | ① §9"旧 Pool 生命周期回收尚未实现"→ **已实现**（关口二/三：MAX_POOLS、max_age=2×window、60s Timer；自动 RETURN/Worker 接管/库存补偿维持 Deferred）；② §4 补 limit=100、batch=10、3 节点×2 Worker 量化示例：**60 令牌 = 瞬时滞留推导上界，60/100=60% = 库存敞口比例（推导上界）**，明确标注**不是实际利用率、不是窗口利用率下限**，实际滞留远小于上界，并给出 Phase 7 实测敞口样本（7848/3.1%）对照 |
| `035447c` | docs/design.md | ② §4.9 EXPIRED 与 EVICTED 区分：**只有 EXPIRED 的未消费库存计入 discarded**；EVICTED 是 **Pool 回收事件（不是 Lease 状态）**，仅淘汰无 ACTIVE Lease 的空池，**零库存损失、不产生 discarded**；③ 新增"不变量的三层区分"：生产代码控制路径（单在途标志 + 非 yield 片段）维护不变量 → `_counters` 账目随状态翻转同步维护 → **`invariants()` 是测试主动调用的校验函数，不是生产运行时断言**（生产路径不调用）；§4.3 前提措辞同步 |
| `02470aa` | docs/design.md | ② 补充：§4.3 少发表行"Pool 过期（EXPIRED）discarded"、§11 配额回收条目措辞同步 |
| `893d432` | docs/architecture.md | ② 术语约定行区分（EXPIRED=唯一产生 discarded 的状态；EVICTED=Pool 回收事件、零库存损失、不是 Lease 状态）；§7 生命周期图注与状态机说明同步；③ 不变量分层说明同步；Deferred 表措辞同步 |

**核实依据（代码核实，实测）**：
- `lease.lua:491 invariants()` 定义；全仓 grep 调用点仅在 test/*.lua 与探针脚本（lease-unit、
  algorithm-lease-unit、lease-grant-smoke、lease-memory-baseline），`kong/` 生产代码零调用。
- `lease.lua` Pool 淘汰仅删除 active 空的池（`evict_idle_pools`/`timer_sweep_once`/
  容量压力淘汰，`_counters.evicted` 计 Pool 数）；`expire_lease_at` 是
  `discarded_tokens` 唯一来源（`lease.lua:15,108-113`）⇒ 只有 EXPIRED 产生 discarded、
  EVICTED 零库存损失，与代码一致。

**测试命令与真实结果**：纯文档修正，无生产代码改动，未新增/重跑测试；测试状态沿用关口四
验收（16 入口 PASS=341/FAIL=0）。范围验证：`git diff` 各提交均仅涉对应文档文件。

**对外行为影响**：无（文档描述修正；EXPIRED/EVICTED 区分与代码实际行为本就一致，属文档对齐）。

**遗留问题**：无新增；既有遗留维持（N1、mermaid 渲染 NOT VERIFIED、长稳少发分布 NOT VERIFIED）。

---

## 关口五最终复审修正（基于 0405e4f，2026-11-15，定点三项，不扩范围）

| 提交 | 文件 | 修正 |
|---|---|---|
| `e27c4fd` | README.md | ① 精度语义块统一 discarded 口径："Pool 过期（EXPIRED，唯一产生 discarded 的状态）… EVICTED 仅为空 Pool 回收事件，零库存损失" |
| `cdf6875` | docs/architecture.md | ① 术语约定行 discarded 定义与 §1 少发来源行统一（EXPIRED 唯一产生 discarded；EVICTED 空 Pool 回收零库存损失）——与 README 同口径 |
| `67c7d7e` | docs/design.md | ② §4.3 前提维护表述改为"**由生产代码控制路径和状态账目维护（单在途标志 + 非 yield 片段 + 计数同步），通过测试中的 invariants() 主动校验**（生产运行时不调用）"，不暗示生产运行时断言；③ §4.3 表头"利用率下限（估算）"→"**瞬时库存敞口比例（推导上界）**"并重算数值（12%/30%/12%/3%，= 瞬时滞留上界/limit），加口径说明与 README 统一（不是实际利用率、不是窗口利用率下限）；§4.4 引用措辞同步 |

**核实依据**：三项均为措辞口径统一；数值换算为同一推导上界的两种表达（原"利用率下限" =
1 − 敞口比例，现统一为敞口比例表述）。EXPIRED/EVICTED 语义与代码一致（上一轮已核实：
discarded_tokens 唯一来源 expire_lease_at；淘汰仅删空池）。

**测试命令与真实结果**：纯文档，无代码改动，未新增/重跑测试（沿用关口四验收状态）。
范围验证：各提交仅涉对应文档文件；openspec/、docs/reports/、bench/、生产代码、Lua、Schema 零改动。

**对外行为影响**：无。

**遗留问题**：无新增；既有遗留维持。

---

## 关口六：次要工程问题（基于 9d02bcb，2026-11-15，可选任务逐项处理）

**执行原则**：先核实（代码 / Kong 3.6 API / 测试入口）再决定；收益不足或无法确认的项目保留现状并记录原因；每项独立提交。

### 任务 1：consumer 匿名维度 —— 保留 `anon`（不改），补文档 + 守护测试

- **核实**：`kong.client.get_forwarded_ip()` 在 Kong 3.6 存在（本插件 ip 维度已使用，`lib/algorithm.lua:75`），IP 取法可行；但**可信性取决于部署侧 `trusted_ips` 配置**，反代场景默认不可信，无法保证。
- **决定：保留 `anon` 原行为**。理由：①分 IP 会把 consumer 配额变成 consumer×ip 双维配额，与 consumer 维度语义不一致；②不可信 IP 会产生攻击者可控的 key 基数（MAX_POOLS 降级可兜底但不理想）；③需按 IP 区分匿名流量应显式 `limit_by` 加 `ip`（现有能力）；④维度值变化 ⇒ 既有匿名桶不可命中（配额重置）。
- **交付**（`b59f6e8`）：`docs/CONFIGURATION.md` 新增 §3.1"维度语义：consumer 的匿名回落"（匿名共享配额 + 不改原因）；新增守护测试 `algorithm-lease-unit` A2（断言未认证 ⇒ `:consumer=anon}`），实测 **37/0**。

### 任务 2：redis.password —— 支持 vault 引用（referenceable）+ E2E

- **核实**：本插件 schema 已有 `redis.password`（纯 string），`lib/redis.lua` 已支持 AUTH（connect 双路径）；Kong 3.6 OSS 官方 `kong.tools.redis.schema` 中 password 即 `encrypted=true, referenceable=true, len_min=0`（容器内实查），OSS 支持 secrets 管理（env vault `{vault://env/<resource>}` 实测可解析）。
- **交付**（`50fc594`）：schema 对齐官方（`encrypted=true, referenceable=true, len_min=0`；DB-less 无落库，encrypted 不影响本仓库运行方式）；新增 `test/redis-password-e2e.sh`：A. vault 引用 `{vault://env/kong-log-level}` 端到端解析 + AUTH 放行 200；B. 明文密码放行 200；C. 密码错误 ⇒ 既有 Fail-close 503。实测 ×2 **5/0**。测试含环境注意事项：schema 属插件代码，**POST /config 只重建 iterator、不重建 Lua VM** ⇒ 测试前置 `docker compose restart kong1` 加载新 schema（已写入脚本并注释）。
- **回归**：`config-isolation-e2e` 14/0、`algorithm-lease-unit` 37/0（schema 变更零破坏）。

### 任务 3：脚本双源一致性自动检查

- **核实**：四个脚本双源（redis/*.lua ↔ lib/redis.lua 内嵌字面量）当前**代码一致**（差异仅为注释：文件版含用法说明、内嵌版含审查编号）；无既有自动检查。
- **交付**（`5b4359d`）：`test/script-consistency-check.sh`——提取内嵌字面量、剥离注释与空行后逐行 diff；不改变运行时加载方式（纯只读检查）。实测 4/0；负向验证：改动代码行可检出（FAIL + diff 输出）。

### 任务 4：仓库整理

- **核实与处置**（`db89f3d`）：
  - `7arg`：多规则 grant 命令的调试残留日志，无引用 ⇒ **删除**。
  - `latency-summary.json`：单次 k6 输出（11-12），无任何报告引用、非 Phase 7 正式数据（Phase 7 原始数据 97 文件在 bench/raw/phase7/）⇒ **删除**。
  - `rule.md`：项目最初 SDD 文档（Historical）⇒ **移至 docs/archive/rule.md**；冻结 openspec 归档中的 prose 引用属历史记录不改，非冻结文档无引用需要修正。
  - `refresh.sh`：开发辅助（restart + FLUSHDB）⇒ **移至 scripts/refresh.sh**（保留功能，无引用需修正）。
  - `reports/` 与 `docs/reports/`：**不合并**——reports/ 为 Phase 1–3 证据，路径被冻结 openspec 归档 change 引用（"产出 reports/phase-1-correctness.md"），移动会破坏冻结 Spec；docs/reports/ 为 Phase 6.3–8.2 报告。已在 docs/README.md 索引中说明。
  - Phase 0 review 两份：**非重复**——`docs/review-phase-0.md`（2026-11-11，Phase 0 审计，被 openspec 归档引用）与 `docs/PHASE0_REVIEW.md`（2026-11-12，Phase 4 实施规范下的现状审查）内容不同 ⇒ **两份均保留**，docs/README.md 已注明。
  - 未动：`rl.json`、`Kong 3-Take home assignment.pdf`（未跟踪，非本清单）、Phase 7 原始数据、全部正式测试与冻结 Spec。
  - **新增 `docs/README.md`** 文档索引（当前使用/设计/阶段报告/归档分类，含不合并理由）。

### 任务 5：CI（.github/workflows/ci.yml）

- **核实**：真实测试入口 = 4 个 resty 单测 + 矩阵/smoke + 11 个 E2E + quota.sh（需 k6）；compose 镜像已固定（kong:3.6 / redis:7-alpine / hashicorp/http-echo:1.0）。
- **交付**（`f48ba10`）：覆盖 ① Lua 语法检查（luajit -bl，10 个 lua 文件全部实测通过）；② 脚本一致性检查；③ 单元测试 4 项；④ Redis 集成（matrix + smoke）；⑤ Kong E2E 全套 11 项（串行、失败聚合、不跳过核心测试）；⑥ bench/quota.sh（安装固定版本 k6 v0.50.0，官方 GitHub release，非镜像站）。
- **不放入 CI 的测试及原因**（workflow 注释中写明）：bench/matrix.sh / k6 latency 压测（长时、共享 Runner 噪声使 p99 归因失效，Phase 7 口径要求专环境）、长稳（>24h）、跨机器 RTT。不跑完整性能矩阵（约束 5）。

### 本关验证汇总（实测）

- 新增/变更测试：algorithm-lease-unit 37/0（+A2）、redis-password-e2e 5/0 ×2、script-consistency-check 4/0（含负向验证）、语法检查 10/10。
- 回归抽查：lease-unit 50/0、config-isolation-unit 24/0、concurrent-lease-e2e 22/0、lease-grant-smoke 7/0、config-isolation-e2e 14/0。
- 范围验证：生产代码仅 schema.lua（任务 2 授权范围）；核心限流语义、Lua 脚本、openspec/、docs/reports/、bench/raw/ 零改动（git diff 核对）。
- CI 工作流 YAML 语法通过；语法检查步骤已在本机同环境实测（CI 完整运行待 push 后首次触发，属 NOT VERIFIED until first run）。

### 未完成项（如实）

- 无"未做"清单项——5 项全部处理。遗留：① CI 首次真实运行未验证（待 push 触发）；② env vault 引用的轮换（TTL update 机制）未验证（超出本关范围）；③ `refresh.sh` 保留于 scripts/（FLUSHDB 为破坏性操作，仅限开发环境——已在脚本所在位置由 TESTING 文档口径约束）。

---
