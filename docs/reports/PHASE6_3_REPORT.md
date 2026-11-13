# Phase 6.3 报告：配置隔离与配置变更 E2E

- **日期**：2026-11-13
- **执行前 HEAD**：`146fdde`（6.2 修正后）；工作区干净（仅 `1113.json` 会话导出未跟踪）
- **任务**：tasks.md 6.3——不同限流策略配置必须使用不同本地 Lease Pool，禁止新配置复用旧库存
- **commit**：`test: complete phase6.3 config isolation evidence`

## 1. 结论：情况 A——现有实现已满足契约，零生产代码修改

| 代码位置 | 证据 |
|---|---|
| `lib/algorithm.lua:35-53` `fingerprint_input` | 指纹输入段：`limit=` / `window=` / `burst=`（经 `rate_and_burst` 归一化：burst≤0 ⇒ limit）/ `limit_by=` 逐维拼接；`header_name=` 仅当 limit_by 含 `header` 维度时追加（无 header 维度时该字段对桶身份无意义，语义正确） |
| `lib/algorithm.lua`（无 batch 段） | `batch` 不参与策略指纹（冻结决策：batch 是传输批量而非策略身份） |
| `lib/algorithm.lua` `build_key` | 桶键 = `prefix:{ns:p=<指纹>:<dim>=<val>...}`；`policy_fingerprint` = FNV-1a32(指纹输入) |
| `lib/lease.lua` `_M._pools[pool_key]` | 本地 Pool 身份 = 该桶键 ⇒ 配置隔离由指纹天然承载，**不存在独立于桶键的第二套 pool_key 体系**（D7） |

## 2. 五个配置维度逐项验证（单测 `config-isolation-unit.sh`，15/15 PASS）

验证对象为**实际 `algorithm.build_key()` 输出**（非独立辅助函数）：

| 维度 | 变更方式 | 结果 |
|---|---|---|
| 完全相同配置 | 两次独立 conf 实例 | key 相同 ✓（same-config-same-key） |
| limit | 100→200 | key 不同 ✓ |
| window | 3600→7200 | key 不同 ✓ |
| burst | 0→5 | key 不同 ✓ |
| limit_by | {ip}→{ip,method}（仅此一个字段，审查修正后单维度独立证明） | key 不同 ✓ |
| header_name | X-A→X-B（两组配置均含 header 维度） | key 不同 ✓ |
| batch（对照） | 10→20 | **key 相同** ✓（冻结：batch 不入指纹） |
| burst=nil vs 0（对照） | 归一化等价（burst≤0⇒limit） | key 相同（语义等价配置，已注明） |

## 3. 本地 Pool 隔离单测（同一套件，transport stub 驱动真实 `check_lease` 路径）

- 配置 A：GRANT granted=5 → 消费 1 → 本地余 4（transport 调用 1 次）
- 配置 B（limit=200 ⇒ 新指纹）：**必须新 GRANT**（transport 再调 1 次 ⇒ 未复用 A 的 4 个库存）、登记 B 自己的 Pool（`_pools[kB] ≠ _pools[kA]`）
- A Pool 逐字段未触碰：`remaining=4 / consumed=1 / active=1`
- A 再次请求：本地 TAKE 成功（transport **零调用**）⇒ A 库存在 B 请求后独立存活
- 相同配置（新 table 实例）⇒ 命中同一 Pool（`_pools[kA3] == _pools[kA]`）

## 4. 配置变更真栈 E2E（`config-isolation-e2e.sh`，14/14 PASS）

真实 Admin API 配置变更（非 mock），limit 100→200、同 namespace：

| 断言 | 实测 |
|---|---|
| 配置 A 首请求 | 200，X-RateLimit-Remaining=9（granted=10 消费 1，本地留 9） |
| 配置 B 首请求 | 200，Remaining=**9**——若复用 A 余 9 库存应为 8 ⇒ **实证不复用** |
| 新 GRANT 触发 | ns lease 记录数=2（B 首请求即新 GRANT） |
| Pool 隔离 | A pool_key `p=50780f62` vs B pool_key `p=95b99e16`（指纹段不同） |
| 并存不覆盖 | B lease_id `...:0:64:32d404` ≠ A lease_id `...:0:63:77be70` |
| A 记录原样 | lease_id / created_at / status=OPEN 全部未变（V1 无 RETURN，旧 Pool 库存自然耗尽/TTL 消亡——冻结决策） |
| 旧桶不动 | A 桶 tokens 90→90（±1 容差=refill/exec 间隔；配置变更不修改旧桶令牌状态） |
| B 桶独立 | B 桶键 ≠ A 桶键 |

维度覆盖口径：E2E 对 **limit** 维度做真实配置变更（§5.2"至少一个维度"）；window/burst/limit_by/header_name 四维度由单测矩阵覆盖（§5.3 允许的组合方式）。

## 5. 回归测试（串行执行）

| 测试 | 结果 |
|---|---|
| `bash test/lease-unit.sh` | PASS 25/25（Lease Manager 零回归） |
| `bash test/algorithm-lease-unit.sh` | PASS 17/17（6.1 零回归） |
| `bash test/algorithm-lease-e2e.sh` | PASS 15/15 |
| `bash test/handler-fault-e2e.sh` | PASS 26/26（6.2 零回归） |
| `bash test/config-isolation-unit.sh` | PASS 15/15 |
| `bash test/config-isolation-e2e.sh` | PASS 14/14 |
| `git diff --check` | ✓ 通过 |
| Phase 0–3 全量（dims.sh/rules.sh/lease-redis-matrix.sh/quota.sh） | **NOT RUN**（属 6.4 全量回归任务组，本组未执行） |

## 6. PASS / FAIL / NOT RUN 统计

- **PASS 112**（15+14+25+17+15+26）/ **FAIL 0** / **NOT RUN：6.4 全量回归套件 + 6.5 并发/异常 E2E + 6.6**
- 无未执行测试被计为 PASS

## 7. 未解决事项

1. 旧 Pool 的本地诊断对象在配置变更后留存于 Worker 内存直至进程结束（`leases` 表只增不删——V1 冻结决策，Phase 5 恢复 RETURN 时引入回收）
2. E2E 仅 limit 维度做了真实变更（单测覆盖全维度）；如需五个维度逐一真实变更 E2E，成本高且增益有限，建议保持现状
3. `burst=nil` 与 `burst=0` 归一化等价（同指纹）——语义等价配置，非缺陷，报告存档

## 8. 进入 Phase 6.4 的结论

- 配置隔离契约全部满足，实现零修改、测试证据完整，可进入 6.4（全量回归 + 故障双路径）。
- 审查修正项（limit_by 单维度化）已落实并重跑通过。
