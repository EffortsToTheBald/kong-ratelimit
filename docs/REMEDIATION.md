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

---

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
