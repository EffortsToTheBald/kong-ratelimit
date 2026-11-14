# Phase 8.2-C 报告：最终交付文档整理

- **日期**：2026-11-14
- **基线 HEAD**：`01b3e11`（第一轮审计提交）；本轮全程零代码/测试/Bench 脚本修改
- **commit**：`docs: finalize phase8c delivery documentation`

## 1. 修改文件清单

| 文件 | 类型 | 内容 |
|---|---|---|
| README.md | 重写 | 面向新用户的项目首页（§五 10 项全部覆盖） |
| docs/architecture.md | 重写 | 当前实现架构（14 项清单覆盖；修复跨 Worker 共享库存错误描述） |
| docs/DEPLOYMENT.md | 新增 | Compose 验证环境部署/检查/排障/清理 |
| docs/CONFIGURATION.md | 新增 | 配置字段全表（以 schema.lua 为唯一依据） |
| docs/TESTING.md | 新增 | 测试运行索引 + 前置条件 + 清理方式 + 报告索引 |
| docs/bench.md | 更新 | 头部加当前口径（Phase 7/8.2-B：matrix 实际默认值、debug 统计口径）；Legacy 表述标注 |
| test/phase1-manual.md | 加注 | 尾部历史口径说明（RL-DEBUG 现为 debug 级）；步骤与结论原样保留 |
| test/phase2-manual.md | 加注 | 同上 |
| docs/reports/PHASE8_C_DOCUMENTATION_AUDIT.md | 第一轮已提交（01b3e11） | — |
| docs/reports/PHASE8_C_DOCUMENTATION_REPORT.md | 新增 | 本报告 |

**零修改**：生产代码（handler/algorithm/lease/redis/schema）、test/*.sh|*.lua 脚本逻辑（仅历史文档加注）、bench/*.sh、k6/、冻结 Spec/Design（design.md/rule.md/openspec/）、Phase 6/7 报告、Phase 8.2-A/B 报告、bench/raw/phase7/ 原始数据、docs/results.md、V1_SCOPE_ADJUSTMENT.md。

## 2. 每份文档的调整内容（对照第一轮审计）

| 审计问题 | 处理 |
|---|---|
| README §6 matrix 命令/默认值/产物过时 | 重写为实测默认（BATCHES=10,50,100 / RATES=100,500,1000 / DUR=20s / debug 级 / 产物 bench/out/results-<TAG>-*.md） |
| README §7 "batch=20 p99 差<1ms" 无证据 | **删除**；性能章节只引 Phase 7（含 p99 NOT VERIFIED 声明） |
| README §5 "典型 p99 增量" 数值 | **删除**；batch 表只保留语义与授权行为（batch=auto 代码证实 clamp(limit/50,1,50)） |
| README 缺三模式概览/自愈说明/字段表/测试索引/报告索引 | 全部补齐（§2/§4/§6/§7/§8/§10） |
| architecture 图 1 "跨 worker 共享库存" | **修正**：Worker 私有 Lease Pool、Lease 归创建 Worker、Worker 间经 Redis 共享全局配额 |
| architecture 图 2 缺 CLOSED/不确定分支 | 重绘：GRANT 四分类 + CLOSED 摘除 + uncertain 不登记 |
| architecture 图 3 SOLVED/OPEN 过时 | 更新：Phase 2 EVALSHA/Phase 4 Lease/Phase 7 性能/Phase 8.2 清理标已完成；Phase 5 Deferred 如实标注 |
| architecture 表 1 Legacy 时代证据 | 重写为分节叙述并标注 Phase 7/6.5 等当前证据来源 |
| architecture 表 2 已完成项仍标 OPEN | 删除/更新 |
| 术语混用（租约/Lease/本地库存） | 统一 Lease（历史引文除外） |
| 配置字段无系统文档 | CONFIGURATION.md 全表（与 schema.lua 逐字段核对，含互斥/校验规则） |
| 测试无运行索引 | TESTING.md（分类 + 前置 + 串行/噪声提醒 + "历史 PASS 不可一键复现"声明） |
| 部署信息分散 | DEPLOYMENT.md 收敛（命令逐一与 compose/脚本核对） |

## 3. 核心架构语义检查（10.2 全项）

| 检查项 | 结果 |
|---|---|
| batch>1 自动归还库存的描述 | ❌ 不存在（全部表述为 Deferred/不自动 RETURN） |
| Worker 之间共享 Lease | ❌ 不存在（明确 Worker 私有、结构隔离） |
| Redis 故障时继续使用未确认库存 | ❌ 不存在（不确定结果不登记、不重试） |
| 多规则使用 Lease | ❌ 不存在（明确不使用、batch 0/1 约束） |
| Redis 异常返回 429 | ❌ 不存在（429=确定性拒绝；故障走 503/降级） |
| Lease TTL 描述成库存归还 | ❌ 不存在（明确"元数据 TTL ≠ 自动归还"） |
| Phase 5 描述成已完成 | ❌ 不存在（全部标 Deferred） |
| Shared Dict 是当前实现 | ❌ 不存在（明确已移除、不依赖） |
| batch>1 与 batch=1 同等时序精度 | ❌ 不存在（明确预授权/突发/损失敞口） |

## 4. 配置字段核对

CONFIGURATION.md 表逐字段对照 schema.lua 实测：limit(必填)/window(60)/burst(0,≤1e8)/batch(0,≤1e8)/
limit_by(7 维 one_of,默认 ip)/header_name(条件必填)/rules(≤8,与 limit_by 互斥,batch∈{0,1})/
namespace(rl)/hide_client_headers(false)/fault_tolerant(false)/redis.{host,port,password,database,timeout,key_prefix}。
**无虚构字段**；LEASE_TTL_MS 未列为用户可配置（明确为内部常量）。

## 5. 命令核对

| 命令 | 核对依据 |
|---|---|
| `docker compose up -d/down/down -v/--force-recreate` | compose 文件 |
| `curl :8031/status` 等管理面端口 8031/8011/8021 | compose ports |
| `./bench/quota.sh -l 100 -b 1 -p 150` | quota.sh getopts "l:b:w:p:h" |
| `./bench/rules.sh` / `dims.sh` | bench/ 实际文件 |
| `bash bench/matrix.sh -b 10 / -w 1 / -L notice` | matrix.sh getopts 与默认值 |
| `bash test/*.sh`（15 个脚本） | test/ 实际文件名 |
| 首请求 `X-RateLimit-Remaining: 19` | 本轮实测（batch auto→20，granted 20 消费 1） |

## 6. 性能数据引用检查

README §8 与 architecture §12 全部数字来自 Phase 7 正式报告（干净轮均值 @1000 w2）：
0.66/1.41/82.8、0.50/1.16/87.1、20001→2002（约 9.99:1）、4773→869（5.5×）、CPU 0.348→0.269/0.079→0.021、
账目 255800/247952/7848（3.1% 未消费/未确认差额）；p99 NOT VERIFIED 如实标注；Legacy 数据仅作历史对照。
无重算、无混用、无新增承诺。

## 7. 内部链接检查

脚本化核对（README/architecture/DEPLOYMENT/CONFIGURATION/TESTING 的 `.md` 相对链接）：**13 个链接全部有效，0 失效**；
README 内部锚点 `#9-已知限制` 已修正。

## 8. 术语一致性

Lease / GRANT_LEASE / GRANT_MULTI / CLOSED / outstanding / lost / batch=1 / batch>1 / Fail-close /
EVALSHA / NOSCRIPT 在五份文档中含义统一；历史报告保留原措辞未动。

## 9. 未解决问题

- 无阻塞性问题。遗留优化项（均已在文档中如实标注）：
  - p99 因果归因 NOT VERIFIED（环境噪声）
  - 旧 Pool 回收 / RETURN / 指标导出 / Cluster / 长稳：Deferred 或未验证
  - phase1/2-manual 的历史操作口径已加注但正文未重写（属历史记录，按约定保留）

## 10. 未验证内容

- Kubernetes / Redis Cluster / 生产 HA / 长稳——文档明确声明"未验证/Deferred"，不得宣称具备
- Phase 7 未覆盖档位（batch=50/100 当前实测、>1000 RPS）——TESTING.md/bench.md 标注

## 11. 最终验收结论

对照任务书 §十三 10 条验收标准：
1–3（新用户理解项目/搭建环境/理解三路径）✓；4–5（Lease 机制/正确配置）✓；6–7（复现主要测试/理解性能收益与局限）✓；
8（无生产成熟度夸大，含"非成熟商业产品"声明）✓；9（与冻结 Design 一致，§3 全项通过）✓；
10（文档/代码/证据无已知矛盾，链接 0 失效）✓。

**结论：Phase 8.2-C 文档整理完成，满足验收标准。**
