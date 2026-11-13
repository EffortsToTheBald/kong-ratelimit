# Phase 6.4 报告：全量回归与故障双路径验证

- **日期**：2026-11-13（v2 修正版）
- **执行前 HEAD**：`f73c0a8`（6.4 初版）；工作区仅本次允许的测试/报告文件
- **本阶段性质**：只做验证与阻断性修复，零生产代码修改
- **commit**：`test: tighten phase6.4 recovery and script cache evidence`

## 0. v2 测试证据修正记录（本次修订内容）

### 修正 1：script-cache-selfheal-e2e.sh 的 SCRIPT EXISTS 检查

- **问题**：初版用 `redis-cli -x SCRIPT LOAD` 生成 sha 再查 EXISTS——即使插件未完成 NOSCRIPT 自愈，测试自己也会把脚本装入缓存，检查结果被污染
- **修正**：从 `redis.lua` 提取内嵌脚本文本 → `sha1sum` 口径（Python `hashlib.sha1`）→ 直接 `SCRIPT EXISTS`，检查前**绝不执行 SCRIPT LOAD**
- **关键细节（v2 过程中发现）**：Lua 长括号 `[[` 后紧跟的首个换行会被 Lua 剥离，插件实际 src 是剥离首行换行后的文本；初版提取（含首行换行）计算的 sha 与插件 sha 不一致（GRANT_LEASE EXISTS=0 实证暴露）。修正后剥离首行换行再计算
- **额外发现（v2 过程中发现）**：FLUSH 后直接请求原 lease 路由可能命中 Worker 本地库存 ⇒ 零 Redis ⇒ grant_lease 根本不触发 NOSCRIPT 重载（实证：TOKEN_BUCKET/GRANT_MULTI EXISTS=1 而 GRANT_LEASE EXISTS=0）。修正为 FLUSH 后下发**新 ns 新路由**（新指纹 ⇒ 新 Pool ⇒ 首请求必 GRANT）
- **修正后实测**：三个脚本 EXISTS 均=1 且与 sha1sum 一致 ⇒ 提取文本与插件 src 逐字节一致 ✓（sha：`c95375…` / `eed403…` / `f89b62…`）

### 修正 2：fault-recovery-e2e.sh 的 R2 场景

- **问题**：初版 R2 并发发 2 个请求却断言超时窗口至多 1 条 Lease 记录——两个独立请求各授权一次可产生 2 条记录，断言不成立（不区分单请求重复申请 vs 独立请求各自授权）
- **修正**：R2 简化为单请求口径：PAUSE 6s → 单请求 503 → PAUSE 过期 → 记录数 ≤1（允许 0：Redis 可能已在超时前执行）→ 新独立请求 200 remaining=9 → 增量恰 +1；并发竞争验证留给 Phase 6.5
- **v2 过程中发现的测试基建问题（非生产代码问题）**：
  1. R1 停机期间 Kong 各 Worker 的 OpenResty DNS 缓存残留 `redis` 主机解析失败（缓存按 Worker 隔离），恢复断言偶发踩到陈旧缓存 ⇒ 503（语义正确但时机未恢复）。修正：对目标路由**轮询至首个 200**——连接拒绝类 503 零写入是确定性事实（请求根本没到 Redis），首个 200 即恢复请求、恰好一次授权，记录数恰 1 的断言因此确定成立
  2. 初版探活用的独立 probe 路由只能证明单个 Worker 连通，不能覆盖其他 Worker 的陈旧 DNS 缓存，已移除、改为对目标路由直接轮询
- **修正后实测**：连续 3 轮全绿（13/0、13/0、12/0——12 为最后一轮无恢复轮询中间尝试）；期间真实复现一次陈旧 DNS 503→恢复，断言全部成立

### 初版（f73c0a8）与 v2 结果对照

| 测试 | 初版结果 | v2 修正后结果 | 说明 |
|---|---|---|---|
| script-cache-selfheal-e2e.sh | PASS 14/14（含被污染的 EXISTS 检查） | **PASS 15/15**（无污染） | 初版 EXISTS 结果作废（污染口径）；v2 另发现提取口径与库存命中两个盲区并修正 |
| fault-recovery-e2e.sh | PASS 12/12（R2 并发口径断言不成立） | **PASS 13/12/13（连续三轮全绿）** | R2 单请求化；R1 场景不变、增加目标路由轮询（时序加固） |
| evalsha-unit.sh | PASS 8/8 | PASS 8/8（重跑） | 无修改 |
| handler-fault-e2e.sh | PASS 26/26 | PASS 26/26（重跑） | 无修改 |
| 其余（quota/dims/rules） | 见 §2–§5 | 引用初版实测（本轮未触及相关路径） | 初版数据仍有效 |

## 1. 测试环境

- 三节点 `kong1/2/3`（每节点 2 Worker）+ 单实例 `redis`；Config API :8031/:8011/:8021，代理 :8030
- 统计口径：`CONFIG RESETSTAT` + `INFO commandstats` 的 `cmdstat_evalsha:calls`（窗口内只含该轮压测 + 配置下发，实测配置下发贡献 0 次 EVALSHA）

## 2. quota.sh batch=1（Spec 场景 1：batch=1 严格路径零变化）

| 轮次 | 结果 | EVALSHA calls | lease 记录 |
|---|---|---|---|
| 第 1 轮 | allowed=100 limited=350 other=0 total=450，**严格等于配额 100 PASS** | — | — |
| RESETSTAT 后 | allowed=100 limited=350 other=0 PASS | **恰 450**（每请求 1 次） | **0** |

- 结论：batch=1 每请求 EVAL，不走本地 Lease，450 恰 100 放行，与 Phase 1 锚点一致；Spec"Redis 中无 Lease 记录"✓
- 锚点变化：无

## 3. quota.sh batch=20（Spec 场景 3：单规则 batch>1 使用 Lease）

| 轮次 | allowed | lease 记录 | EVALSHA calls |
|---|---|---|---|
| 第 1 轮 | **80** ∈ [40,100] PASS | 5 条（各 granted=20，status=OPEN） | — |
| 第 2 轮 | 100（利用率 100% PASS） | —（窗口内 355 次） | **355** |

- **账目核验（355 = 350 + 5）**：450 请求 = 95 次纯本地 TAKE（零 Redis，= 100 allowed − 5 池首 GRANT）+ 5 次 granted-GRANT + 350 次 denied-GRANT（库存耗尽 ⇒ 申请被桶拒 ⇒ granted=0 ⇒ 429，冻结设计"耗尽即新 Lease 申请"）
- 不超发（allowed ≤ limit）；GRANT 批量授权 + 本地 TAKE + 耗尽重新申请 ✓；denied-GRANT 属 miss 路径一次 EVAL（全局一致性由 GRANT 脚本桶检查保证），非"每请求 Redis 操作"

## 4. dims.sh 回归

**PASS 8/8**：IP / Path / Client ID / Header 等现有维度全绿——维度值隔离、正确命中桶、Header 配置生效、配置指纹不破坏维度隔离、batch>1 Lease 路径不破坏维度限流语义

## 5. rules.sh 回归（Spec 场景 2：多规则路径零变化）

**PASS 14/14**，含核心场景"预置一空一有 ⇒ 429 且双桶 tokens 均不变"；多规则全或无、合法放行、429/Retry-After 语义全绿；未修改多规则算法或 Lua 协议；多规则零 Lease 记录由 6.2 组 `algorithm-lease-e2e.sh` 断言与本轮共同覆盖

## 6. 故障双路径

### 6.1 handler-fault-e2e.sh（PASS 26/26，v2 重跑）

- 连接拒绝：batch=1 与 batch>1 均 503（ft=false）/ 降级（ft=true）；故障不伪装 429 ✓
- CLIENT PAUSE 6s 超时：batch=1 进既有故障分支；batch>1 不确定结果 ⇒ 503、不重复申请、不登记本地库存、不伪装令牌不足 ✓
- 双 Worker [0,1] 持库存 ✓

### 6.2 fault-recovery-e2e.sh（v2 修正后，PASS 13/0、13/0、12/0 连续三轮全绿，§7.3）

- R1 连接拒绝→恢复（场景不变，恢复断言经目标路由轮询加固）：故障期 503 ⇒ 恢复 ⇒ 200 remaining=9；**该 ns lease 记录恰 1 条**（停机零写入 + 首个 200 单次授权，无重复授权）
- R2 超时→恢复（单请求口径）：PAUSE 6s ⇒ 单请求 503（不重试、不伪装 429）；PAUSE 过期 ⇒ 记录数 0 ≤1（允许 0 或 1）；新独立请求 200 remaining=9；**增量恰 +1** ⇒ 无重复授权；实测中真实复现一次陈旧 DNS 503→恢复，断言全部成立
- 不确定结果不登记本地库存、不重复申请（6.2 组语义）由 handler-fault-e2e 超时场景覆盖

## 7. EVALSHA 缓存丢失自愈（§8）

### 7.1 script-cache-selfheal-e2e.sh（v2 修正后，PASS 15/15）

- 三模式 FLUSH 前各 200（懒加载 EVALSHA 正常）
- `SCRIPT FLUSH` 后：batch=1、多规则各请求 200；**新 ns lease 路由**首请求 200（保证 grant_lease 必触发 NOSCRIPT；本地库存命中路径零 Redis 不触发重载——v2 发现并修正的盲区）
- `SCRIPT EXISTS`（sha1sum 口径、零 SCRIPT LOAD 污染）：三脚本均=1 ⇒ 插件自愈装回且提取文本与插件 src 逐字节一致（Lua 首行换行剥离口径实证）
- 日志无 `script still missing after reload` / `script load failed`

### 7.2 静态单测 evalsha-unit.sh（PASS 8/8，v2 重跑）

- NOSCRIPT ⇒ LOAD ⇒ 恰一次重试；重试后仍 NOSCRIPT ⇒ 明确失败、无第二次 LOAD（不无限重试）
- **超时 ⇒ 不触发 LOAD**（绝不当作 NOSCRIPT）
- LOAD 失败等错误路径不破坏 Phase 2 行为

## 8. Spec 适用边界三场景逐项验证（spec.md `Lease 模式适用边界` Requirement 原文）

| # | 场景定义（原文） | 预期行为 | 测试脚本 | 实际结果 | 满足 Spec |
|---|---|---|---|---|---|
| 1 | **batch=1 严格路径零变化**："以 batch=1 配置复跑 Phase 1 基线（450 请求恰 100 放行）与故障双路径" | 结果与既有锚点一致，Redis 中无 Lease 记录 | quota.sh -b 1 + handler-fault-e2e.sh + RESETSTAT 口径 | 450 恰 100/350/0 两轮一致；EVALSHA 恰 450；lease 记录 0；故障双路径 26 断言全绿 | ✓ |
| 2 | **多规则路径零变化**："复跑 rules.sh 全场景" | 全绿且 Redis 中无 Lease 记录；"一空一有 ⇒ 429 且双桶不变"语义不变 | rules.sh（14 场景）+ algorithm-lease-e2e.sh 多规则零 lease 断言 | PASS 14/14；核心场景 ✓；多规则零 Lease ✓ | ✓ |
| 3 | **单规则 batch>1 使用 Lease**："以 batch=20 配置发起请求" | 首次请求经 GRANT 创建 Lease（Redis 可见 lease 记录，状态 OPEN），后续请求本地 TAKE 消费，无每请求 Redis 操作 | quota.sh -b 20 + RESETSTAT 账目核验 | lease 记录 OPEN granted=20；95 池命中请求零 Redis；耗尽重新申请 ✓ | ✓ |

未改写任何 Spec 验收口径；实现与冻结 Spec 无冲突。

## 9. PASS / FAIL / NOT RUN 统计（v2）

| 项目 | 结果 | 口径 |
|---|---|---|
| quota.sh -b 1（两轮+账目） | PASS | 实际执行（v1/f73c0a8 版报告实测，本轮未复跑：batch=1 路径无改动） |
| quota.sh -b 20（两轮+账目） | PASS | 实际执行（同上） |
| dims.sh | PASS 8/8 | 实际执行（同上） |
| rules.sh | PASS 14/14 | 实际执行（同上） |
| handler-fault-e2e.sh | PASS 26/26 | **v2 实际重跑** |
| fault-recovery-e2e.sh | PASS 13/0、13/0、12/0 | **v2 修正后实际执行×3** |
| script-cache-selfheal-e2e.sh | PASS 15/15 | **v2 修正后实际执行** |
| evalsha-unit.sh | PASS 8/8 | **v2 实际重跑** |
| Phase 6.1–6.3 套件（lease-unit 25 / algorithm-lease-unit 17 / algorithm-lease-e2e 15 / config-isolation 15+14） | 引用 6.1–6.3 已验证结果 | 静态代码检查（本轮未复跑，相关实现零改动） |
| **合计** | **FAIL 0**；v2 实测断言（最近一轮）：26 + 12 + 15 + 8 = **61 PASS**；初版 quota/dims/rules 实测记录（quota 两轮、dims 8、rules 14）仍有效 | |
| NOT RUN | Phase 6.5 并发与异常 E2E、6.6 最终交付 | 未执行 |

（统计说明：fault-recovery 连续三轮 13/13/12 全绿，合计取最近一轮 12；三轮明细均在 §6.2 存档。）

## 10. 发现的问题及修复记录

- **生产代码零修改**（两处修正均为测试证据口径修正）
- v2 过程发现并修正的测试盲区（均为测试自身问题，非实现回归）：
  1. EXISTS 检查被 SCRIPT LOAD 自污染 → 改 sha1sum 口径
  2. Lua 长括号首行换行剥离导致提取 sha 与插件 src 不一致 → 剥离后计算
  3. FLUSH 后 lease 路由命中本地库存 ⇒ grant_lease 不触发重载 → 新 ns 新路由强制 GRANT
  4. R2 并发请求的记录数断言不成立 → 单请求化（并发验证留 6.5）
  5. OpenResty DNS 缓存按 Worker 隔离的陈旧解析残留 → 目标路由轮询至首个 200（连接类 503 零写入确定性）
- quota b20 两轮 allowed=80/100：Worker 分配差异的合法区间波动，非回归

## 11. 进入 Phase 6.5 的条件

- batch=1 零回归 ✓；batch>1 Lease 路径正确 ✓；维度/多规则零回归 ✓；故障双路径符合既有语义 ✓（修正后测试实际通过）；EVALSHA 自愈三脚本无污染实证 ✓；Spec 三场景全部满足 ✓
- **结论：满足进入 Phase 6.5（并发与异常 E2E）的条件，且以 v2 修正后测试实际通过为前提**
