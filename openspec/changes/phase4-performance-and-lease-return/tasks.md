# Tasks

> 规格依据：`specs/rate-limiting/spec.md`（9 条 ADDED）；实现依据：`design.md`（D1–D8 + 不变量表 + Future Considerations）+ 最终实施规范（Phase 0–8、commit 规范、禁止事项）。
> **阶段编号映射（2026-11-13 裁决）**：本文件任务组 3/4/5/6 ↔ 实施规范 Phase 3/4/5/6；Phase 7（性能第三组）与 Phase 8（清理）按规范独立阶段执行。**Lease Key = `kong:rl:lease:{lease_id}`**（遵循 kong:rl 前缀；Cluster Slot 一致性不在本阶段保证范围）。**阈值字段名统一 `idle_threshold`**。Phase 3 开工核对结论见本轮对话与 commit 记录（无阻塞性冲突）。
> **执行原则**：先检查代码再修改；Phase 0 只审查不改生产代码；不跳阶段、不混提交；测试失败即停；不修改测试预期（除非证明原测试有误并说明）；NOT RUN 如实标注；不保留两套生产限流实现；发现规范与代码冲突先报告。

## Phase 0：代码现状审查（不修改生产代码）

- [x] 0.1 审查现有实现并输出 `docs/PHASE0_REVIEW.md`：当前架构与关键函数、Bucket 字段（tokens/ts）与 rate/capacity 来源（ARGV）、Bucket TTL 策略（2×window）、EVAL 调用路径、多规则原子实现、batch>1 现有库存逻辑（store.lua shared dict）、Worker 初始化/退出与 timer 现状、Redis Key 设计、配置 Schema、与本规范的差异清单、兼容性影响、实施风险；有阻塞性不兼容 ⇒ 暂停编码先报告；验证：报告覆盖实施规范 §14 的 10 项内容且事实与代码一致
- [x] 0.2 输出需修改文件清单、设计冲突、Phase 1 执行计划；验证：见 PHASE0_REVIEW.md §差异/§文件清单/§Phase 1 计划

## Phase 1：EVAL 基线（`test: add phase4 eval performance baseline`）

- [x] 1.1 环境自检 + 基线 commit（树干净则 `--allow-empty` 锚点）；验证：`docker compose ps` 全部 running
- [x] 1.2 首日事实核查（阻塞项前置）：LuaJIT FFI `clock_gettime(CLOCK_MONOTONIC)` 可用性（ABI/返回值/错误处理/容器兼容）；`CLIENT PAUSE` 可用性；Worker 级模块 table 隔离实证；验证：resty 输出留档；**单调时钟核查不通过 ⇒ 停止 Phase 5 生命周期实现并报告**（不阻塞 Phase 1/2）
- [x] 1.3 `matrix.sh` 扩展第一组维度：batch 1/10/50/100、速率低/中/高、Worker 1/多、单/多规则、Redis CPU（INFO cpu 差值）、Kong CPU、commandstats 分类列；验证：单组 dry-run 通过
- [x] 1.4 执行 EVAL 基线 → `bench/results.md` 基线段（含原始数据保存）；验证：数据真实、同参数可在 Phase 2/7 复跑
- [x] 1.5 commit `test: add phase4 eval performance baseline`；验证：git log 出现该提交（`8b04976`）

## Phase 2：EVALSHA（`feat: add evalsha script management`）

- [x] 2.1 统一脚本注册（**实施偏差：Phase 2 仅接入既有两脚本 TOKEN_BUCKET/GRANT_MULTI**，GRANT_LEASE/RETURN_LEASE 待 Phase 3 注册；懒加载取代 init timer——两者均满足 spec"定时或懒加载"）+ evalsha 包装（明确 NOSCRIPT ⇒ LOAD ⇒ 重试恰一次；超时不触发 LOAD）+ 错误类别透传；验证：resty 单测 8 用例全绿（`test/evalsha-unit.sh`，含 NOSCRIPT 重试计数=1、超时/断开不触发 LOAD、LOAD 失败、懒加载）
- [x] 2.2 E2E：SCRIPT FLUSH（隔离测试 Redis）后分别经 batch=1 与多规则路径验证自愈（200 + warn 日志 token_bucket/grant_multi；commandstats eval 不再增长/evalsha=N）+ **多 Worker 独立懒加载实证**（三节点 miss 计数与请求分布一致）；init 期停 Redis 子项：懒加载语义下初始化本身无 Redis IO（由故障回归覆盖）；验证：spec（EVALSHA）四场景
- [x] 2.3 回归：quota.sh batch=1（100/350/0）+ dims.sh + rules.sh 全绿；验证：spec（EVALSHA·行为零回归）
- [x] 2.4 第二组性能测试（与第一组同参数，仅脚本调用方式不同）→ results.md EVALSHA 对比段；验证：不得混入其他逻辑变化
- [x] 2.5 commit `feat: add evalsha script management`；验证：git log

## Phase 3：Redis Lease 数据模型（`feat: add redis lease grant and return scripts`；不接请求路径）

- [x] 3.1 `redis/grant_lease.lua`（独立裸跑）与内嵌 GRANT_LEASE 双源：KEYS[1]=桶键、KEYS[2]=kong:rl:lease:{lease_id}、ARGV=[batch,lease_ttl_ms,lease_id,pool_key,rate,capacity,bucket_ttl_ms]（rate/capacity/bucket_ttl 与其他脚本统一 ARGV 方案）；三阶段（参数校验 ⇒ EXISTS ⇒ LEASE_EXISTS；桶类型/字段校验 ⇒ refill(elapsed=max(0,now−ts))/granted=min(batch,floor(tokens))/tokens<1 ⇒ granted=0 不建记录/扣桶 + HSET lease(status=OPEN,granted,pool_key,created_at=Redis TIME) + PEXPIRE）；验证：双源 diff 空 + resty 裸跑矩阵（满桶/部分授予/不足 granted=0 无记录/LEASE_EXISTS/参数与桶字段非法 ⇒ 零写入）
- [x] 3.2 `redis/return_lease.lua`（独立裸跑）与内嵌 RETURN_LEASE 双源：**幂等提交点先行**——KEYS[1]=kong:rl:lease:{lease_id}、KEYS[2]=桶键、ARGV=[requested,pool_key,bucket_ttl_ms,rate,capacity]；校验（requested 非负整数<2^53 ⇒ INVALID_ARGUMENT；不存在 ⇒ LEASE_NOT_FOUND；RETURNED ⇒ 同 requested ALREADY_RETURNED/不同 RETURN_CONFLICT；非 OPEN/POOL_MISMATCH/requested>granted 拒绝；桶不存在 ⇒ BUCKET_NOT_FOUND；桶字段非法拒绝——均零写入）⇒ 提交点 HSET lease(status=RETURNED,return_requested) ⇒ requested>0 ⇒ refill→+requested→capacity 封顶 ⇒ 一次 HSET 完整桶状态 + TTL ⇒ 返回 {requested,applied,discarded}；验证：双源 diff 空 + resty 裸跑矩阵（§5.9 十二项全覆盖：正常/重复同参桶不增/异参 RETURN_CONFLICT/并发两 RETURN 桶只增一次/requested=0 转状态/requested=granted/requested>granted 拒/Lease 过期 LEASE_NOT_FOUND/Bucket 过期 BUCKET_NOT_FOUND 零写入/参数非法零写入）
- [x] 3.3 标记后桶更新失败测试：注入 RETURNED 提交后、桶 HSET 前失败 ⇒ 重试 ALREADY_RETURNED 桶不增、差额计损失；验证：spec（幂等提交点场景）
- [x] 3.4 Lease TTL：GRANT 侧公式 `lease_ttl = lease_max_lifetime + 3×redis_timeout_s + 60`（统一不缩短；RETURNED 不缩 TTL）；验证：PTTL 断言 == 公式值。**V1 注记（2026-11-13）**：该公式为 Phase 3 历史验证口径（Lua 实现保留）；V1 调用语义改为固定 lease_ttl 常量（见 design D4/Phase 4 范围），不代表 V1 依赖 lease_max_lifetime 配置
- [x] 3.5 refill 语义一致性测试向量：四脚本（TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE）以相同桶状态+相同 TIME 输入跑相同向量 ⇒ refill 结果一致；验证：测试向量表留档
- [x] 3.6 组测试报告 + commit `feat: add redis lease grant and return scripts`；验证：git log

## Phase 4：Worker 本地 Lease（`feat: add worker local lease manager`；不接扫描器，先单测）

> **V1 范围（2026-11-13 裁决）**：状态机简化 **ACTIVE→CLOSED**（库存耗尽 ⇒ CLOSED/本地删除，无 CLOSING 归还态、无 Redis RETURN 调用）；无生命周期阈值/时钟/扫描器；Worker 崩溃 ⇒ 剩余库存损失（不恢复不补偿）。

- [x] 4.1 新增 `lib/lease.lua`（Worker 级模块表）：pools/leases 结构、lease 对象（lease_id/pool_key/granted/remaining/consumed/status/created_at——**V1 无 idle_threshold/max_lifetime/last_used_at**；不变量 remaining+consumed=granted、0≤remaining≤granted）；验证：resty 单测（结构断言 + remaining/consumed 守恒）
- [x] 4.2 TAKE（非 yield 同步片段：查 ACTIVE→remaining>0→remaining−−→consumed++→ALLOW；无 ⇒ NEED_GRANT；不访问 Redis、无等待、无补偿路径；**V1 无 last_used_at 更新**——无 idle 判定消费者）；验证：resty 单测（递减/归零不可再取/多 Lease 插入序取用/remaining≥0 结构断言）+ yield 探针断言片段内无 yield
- [x] 4.3 耗尽处理（V1 简化）：remaining=0 ⇒ Lease 标记 CLOSED/从 ACTIVE 集合移除（本地先行，同一非 yield 片段）；CLOSED 不可复活、不可重复消费；**无 RETURN 调用、无快照步骤**；验证：resty 单测（耗尽后 TAKE 不选中/CLOSED 不可复活/重复标记跳过）
- [x] 4.4 GRANT 调用接线（lease_id 生成：hostname+worker+计数+随机；GRANT_LEASE 调用与结果分类：成功建本地 Lease/granted=0/LEASE_EXISTS 与其他明确错误 ⇒ 故障分支/**不确定 ⇒ 不重试允许损失**；本地 `remaining+consumed=granted` 维护）；**多 Lease 并存**：同 pool_key 多 Lease 各自独立 lease_id、GRANT 成功后非 yield 段登记（追加不覆盖）、TAKE 遍历选有剩余者；Redis 已原子扣桶 ⇒ 并存无重复分配；验证：resty 单测（GRANT 成功/不足/冲突/不确定四分类 + 多 Lease 并存）+ **不得出现 remaining>granted 与负库存**结构断言
- [x] 4.5 多 Worker 隔离：A/B 各自 Lease 互不可见互不代管；A 崩溃（table 丢弃）不影响 B 且不重新授权；验证：resty 双 VM/分进程验证 + spec（所有权场景）
- [x] 4.6 组测试报告 + commit `feat: add worker local lease manager`；验证：git log

## Phase 5：Lease 生命周期 —— **DEFERRED / OUT OF SCOPE FOR V1**

> **2026-11-13 裁决**：本阶段整体 **V1 不实施**。V1 采用"库存耗尽即损失"的保守模型（Phase 4.3），不实现自动归还。以下任务原样保留为 Phase 5 恢复时的规范，**不得**偷偷合并进 Phase 4 或 Phase 6。

- [ ] 5.1 【DEFERRED】单调时钟落地（FFI CLOCK_MONOTONIC；核查不通过 ⇒ 停止本 Phase 并报告）
- [ ] 5.2 【DEFERRED】每 Worker 扫描器 + sweeping 重入保护 + 失败隔离 + 延迟记录
- [ ] 5.3 【DEFERRED】idle/max 关闭触发（阈值取 Lease 创建快照；idle=0 仅 max 生效）
- [ ] 5.4 【DEFERRED】RETURN 有限重试策略落地（仅 uncertain，原 ID+原 requested，≤3 次）
- [ ] 5.5 【DEFERRED】配置快照与隔离 E2E（POOL_MISMATCH 拒绝路径 E2E）
- [ ] 5.6 【DEFERRED】组测试报告 + commit `feat: add lease lifecycle and idle return`

## Phase 6：请求路径集成（`feat: integrate worker lease into rate limit path`；V1 核心阶段）

> **V1 范围**：只接 batch>1 的 Lease 消费与申请；**无扫描器启动、无 SIGTERM 归还、无关闭/RETURN 交错**（库存耗尽 ⇒ 新 Lease）。

- [ ] 6.1 `algorithm.lua` 接线：单规则 batch>1 ⇒ TAKE → NEED_GRANT ⇒ GRANT_LEASE → 建本地 Lease/消费 1；granted=0 ⇒ 429；**batch=1 与多规则路径一行不动**；验证：resty 单测 + 三模式行为矩阵
- [ ] 6.2 `handler.lua`：故障分支接线核对（Redis 不可用 ⇒ 既有 503/降级语义不被 Lease 改变；不得用 Lease 绕过 Fail-close；429/503 语义不混淆）；**V1 无扫描器启动**；验证：启动日志 + 故障注入
- [ ] 6.3 配置隔离核对：pool_key 指纹覆盖 limit/window/burst/limit_by/header_name ⇒ 不同配置不共用本地库存；如有不明确处先报告再动；验证：配置变更 E2E（新旧 Lease 隔离）
- [ ] 6.4 全量回归：quota.sh（batch=1 基线 100/350/0 + batch=20 区间——锚点变化注明原因）+ dims.sh + rules.sh 全绿；故障双路径；脚本缓存丢失自愈；验证：spec（适用边界三场景 + EVALSHA 零回归）
- [ ] 6.5 并发与异常 E2E（V1 口径）：多 Worker 并发 TAKE/GRANT 全局额度正确（不超发）；本地并发 TAKE 不重复消费；库存耗尽 ⇒ 新 Lease 流程正确；kill -9 ⇒ 损失核验（granted−consumed=lost，不超发不重新授权）；Redis 超时不重复申请；验证：spec（所有权/账目场景）
- [ ] 6.6 组测试报告 + commit `feat: integrate worker lease into rate limit path`；验证：git log

## Phase 7：核心正确性与性能验证（`test: add phase4 lease performance report`；V1 压缩版）

- [ ] 7.1 正确性测试 11 项：①多 Worker 并发申请不超发 ②本地并发 TAKE 不重复消费 ③remaining≥0 ④耗尽重申请流程 ⑤kill -9 损失不重新发放 ⑥batch=1 无 Lease 记录 ⑦多规则无 Lease 记录 ⑧多规则全或无 ⑨Fail-close ⑩429+Retry-After ⑪quota/dims/rules 回归；验证：E2E 断言逐项
- [ ] 7.2 性能三点：M0（复用 Phase 1 数据）+ batch=1 + batch=10（Worker 1/多 × 速率低中高）；采集 RPS/p50/p95/p99/Redis QPS；重点验证 batch=10 是否显著降低 Redis 请求次数且保持限流正确性；验证：与 Phase 1 同口径
- [ ] 7.3 Phase 3 矩阵证据核对：确认 `test/lease-redis-matrix.sh` 50 项与当前最终代码版本对应（必要时仅跑 smoke：GRANT 正常/RETURN 幂等/TTL 校验抽测）；验证：核对记录
- [ ] 7.4 报告体例：编号/目的/环境/配置/参数/实际量/时长/RPS/p50/p95/p99/Redis QPS/异常/结论；未执行项 NOT RUN；原始数据入库；验证：体例符合
- [ ] 7.5 commit `test: add phase4 lease performance report`；验证：git log

## Phase 8：清理与最终交付（`refactor: remove legacy local inventory implementation`；仅当全部测试通过）

- [ ] 8.1 删除 `lib/store.lua` 及全部引用、compose 的 `KONG_NGINX_HTTP_LUA_SHARED_DICT` 与相关 docs 段落、重复/不可达代码；验证：grep 无残留 + 启动正常 + 全量回归仍全绿
- [ ] 8.2 最终交付文档：架构图、请求处理流程图、Lease 授权与本地消费流程图、README（Lease 模式与错误码语义）、**Production TODO**（Cluster/Worker 接管/SIGTERM 可靠归还/idle 自动归还/CLOCK_MONOTONIC 生命周期/精确总账/多规则 Lease/batch 调优/预取策略/soak/监控审计/自动回收——均标注"未实现，属延期"）；验证：文档与实现一致、延期项与已交付项无混淆
- [ ] 8.3 最终代码审查 + commit `refactor: remove legacy local inventory implementation`；验证：git log


- 全部 Phase 完成且人工验收通过后执行 `openspec archive phase4-performance-and-lease-return`（9 条 ADDED 追加合入主 spec）。
- 遗留输入（Deferred）：GRANT 幂等、Redis Cluster、精确生产总账、Worker 接管、SIGTERM 可靠归还、多规则 β、Lease 清理索引。
