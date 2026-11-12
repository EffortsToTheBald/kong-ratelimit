# Tasks

> 规格依据：`specs/rate-limiting/spec.md`（9 条 ADDED）；实现依据：`design.md`（D1–D8 + 不变量表 + Future Considerations）+ 最终实施规范（Phase 0–8、commit 规范、禁止事项）。
> **执行原则**：先检查代码再修改；Phase 0 只审查不改生产代码；不跳阶段、不混提交；测试失败即停；不修改测试预期（除非证明原测试有误并说明）；NOT RUN 如实标注；不保留两套生产限流实现；发现规范与代码冲突先报告。

## Phase 0：代码现状审查（不修改生产代码）

- [x] 0.1 审查现有实现并输出 `docs/PHASE0_REVIEW.md`：当前架构与关键函数、Bucket 字段（tokens/ts）与 rate/capacity 来源（ARGV）、Bucket TTL 策略（2×window）、EVAL 调用路径、多规则原子实现、batch>1 现有库存逻辑（store.lua shared dict）、Worker 初始化/退出与 timer 现状、Redis Key 设计、配置 Schema、与本规范的差异清单、兼容性影响、实施风险；有阻塞性不兼容 ⇒ 暂停编码先报告；验证：报告覆盖实施规范 §14 的 10 项内容且事实与代码一致
- [x] 0.2 输出需修改文件清单、设计冲突、Phase 1 执行计划；验证：见 PHASE0_REVIEW.md §差异/§文件清单/§Phase 1 计划

## Phase 1：EVAL 基线（`test: add phase4 eval performance baseline`）

- [ ] 1.1 环境自检 + 基线 commit（树干净则 `--allow-empty` 锚点）；验证：`docker compose ps` 全部 running
- [ ] 1.2 首日事实核查（阻塞项前置）：LuaJIT FFI `clock_gettime(CLOCK_MONOTONIC)` 可用性（ABI/返回值/错误处理/容器兼容）；`CLIENT PAUSE` 可用性；Worker 级模块 table 隔离实证；验证：resty 输出留档；**单调时钟核查不通过 ⇒ 停止 Phase 5 生命周期实现并报告**（不阻塞 Phase 1/2）
- [ ] 1.3 `matrix.sh` 扩展第一组维度：batch 1/10/50/100、速率低/中/高、Worker 1/多、单/多规则、Redis CPU（INFO cpu 差值）、Kong CPU、commandstats 分类列；验证：单组 dry-run 通过
- [ ] 1.4 执行 EVAL 基线 → `bench/results.md` 基线段（含原始数据保存）；验证：数据真实、同参数可在 Phase 2/7 复跑
- [ ] 1.5 commit `test: add phase4 eval performance baseline`；验证：git log 出现该提交

## Phase 2：EVALSHA（`feat: add evalsha script management`）

- [ ] 2.1 统一脚本注册（四脚本：TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE；src+SHA，名称唯一稳定、文本不重复维护）+ init_worker timer 延迟加载（失败 warn 一次）+ evalsha 包装（明确 NOSCRIPT ⇒ LOAD ⇒ 重试恰一次；超时不触发 LOAD；连续失败明确错误进故障分支）+ 错误类别透传；验证：resty 单测（四脚本各自 NOSCRIPT 注入重试计数=1、超时不触发 LOAD、LOAD 畸形、懒加载、初始化不受阻）
- [ ] 2.2 E2E：SCRIPT FLUSH 后分别经 batch=1 路径与多规则路径验证自愈且不重复扣减（HGET 前后对照）；init 期停 Redis ⇒ 正常初始化、首请求按 conf 走 503/降级；commandstats eval=0/evalsha=N；验证：spec（EVALSHA）四场景
- [ ] 2.3 回归：quota.sh batch=1（100/350/0）+ dims.sh + rules.sh 全绿；验证：spec（EVALSHA·行为零回归）
- [ ] 2.4 第二组性能测试（与第一组同参数，仅脚本调用方式不同）→ results.md EVALSHA 对比段；验证：不得混入其他逻辑变化
- [ ] 2.5 commit `feat: add evalsha script management`；验证：git log

## Phase 3：Redis Lease 数据模型（`feat: add redis lease grant and return scripts`；不接请求路径）

- [ ] 3.1 `redis/grant_lease.lua`（独立裸跑）与内嵌 GRANT_LEASE 双源：KEYS[1]=桶键、KEYS[2]=lease:{lease_id}、ARGV=[batch,lease_ttl_ms,lease_id,pool_key,rate,capacity]（rate/capacity 与其他脚本统一 ARGV 方案）；三阶段（参数校验 ⇒ EXISTS ⇒ LEASE_EXISTS；桶类型/字段校验 ⇒ refill(elapsed=max(0,now−ts))/granted=min(batch,floor(tokens))/tokens<1 ⇒ granted=0 不建记录/扣桶 + HSET lease(status=OPEN,granted,pool_key,created_at=Redis TIME) + PEXPIRE）；验证：双源 diff 空 + resty 裸跑矩阵（满桶/部分授予/不足 granted=0 无记录/LEASE_EXISTS/参数与桶字段非法 ⇒ 零写入）
- [ ] 3.2 `redis/return_lease.lua`（独立裸跑）与内嵌 RETURN_LEASE 双源：**幂等提交点先行**——KEYS[1]=lease:{lease_id}、KEYS[2]=桶键、ARGV=[requested,pool_key,bucket_ttl_ms,rate,capacity]；校验（requested 非负整数<2^53 ⇒ INVALID_ARGUMENT；不存在 ⇒ LEASE_NOT_FOUND；RETURNED ⇒ 同 requested ALREADY_RETURNED/不同 RETURN_CONFLICT；非 OPEN/POOL_MISMATCH/requested>granted 拒绝；桶不存在 ⇒ BUCKET_NOT_FOUND；桶字段非法拒绝——均零写入）⇒ 提交点 HSET lease(status=RETURNED,return_requested) ⇒ requested>0 ⇒ refill→+requested→capacity 封顶 ⇒ 一次 HSET 完整桶状态 + TTL ⇒ 返回 {requested,applied,discarded}；验证：双源 diff 空 + resty 裸跑矩阵（§5.9 十二项全覆盖：正常/重复同参桶不增/异参 RETURN_CONFLICT/并发两 RETURN 桶只增一次/requested=0 转状态/requested=granted/requested>granted 拒/Lease 过期 LEASE_NOT_FOUND/Bucket 过期 BUCKET_NOT_FOUND 零写入/参数非法零写入）
- [ ] 3.3 标记后桶更新失败测试：注入 RETURNED 提交后、桶 HSET 前失败 ⇒ 重试 ALREADY_RETURNED 桶不增、差额计损失；验证：spec（幂等提交点场景）
- [ ] 3.4 Lease TTL：GRANT 侧公式 `lease_ttl = lease_max_lifetime + 3×redis_timeout_s + 60`（统一不缩短；RETURNED 不缩 TTL）；验证：PTTL 断言 == 公式值
- [ ] 3.5 refill 语义一致性测试向量：四脚本（TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE）以相同桶状态+相同 TIME 输入跑相同向量 ⇒ refill 结果一致；验证：测试向量表留档
- [ ] 3.6 组测试报告 + commit `feat: add redis lease grant and return scripts`；验证：git log

## Phase 4：Worker 本地 Lease（`feat: add worker local lease manager`；不接扫描器，先单测）

- [ ] 4.1 新增 `lib/lease.lua`（Worker 级模块表）：pools/leases 结构、lease 对象（lease_id/pool_key/granted/remaining/consumed/status/created_at/last_used_at/idle_threshold/max_lifetime——阈值为创建时快照；不变量 remaining+consumed=granted、0≤remaining≤granted）；时钟经可注入单调接口；验证：resty 单测（结构断言 + 时钟注入）
- [ ] 4.2 TAKE（非 yield 同步片段：查 ACTIVE→remaining>0→remaining−−→consumed++→last_used_at 更新→ALLOW；无 ⇒ NEED_GRANT；不访问 Redis、无等待、无补偿路径）；验证：resty 单测（递减/归零不可再取/多 Lease 插入序取用/remaining≥0 结构断言）+ yield 探针断言片段内无 yield
- [ ] 4.3 状态机与唯一关闭流程：ACTIVE→CLOSING→CLOSED 单向；关闭步骤（ACTIVE 检查/条件判定/置 CLOSING/从 ACTIVE 集合摘除/requested=remaining/remaining=0/置 CLOSED）同一非 yield 片段；关闭后不可消费、不可复活、不重复关闭；验证：resty 单测（关闭后 TAKE 不选中/CLOSED 不可复活/重复关闭跳过）
- [ ] 4.4 GRANT 调用接线（lease_id 生成：hostname+worker+计数+随机；GRANT_LEASE 调用与结果分类：成功建本地 Lease/granted=0/LEASE_EXISTS 与其他明确错误 ⇒ 故障分支/不确定 ⇒ 不重试允许损失；本地 `remaining+consumed=granted` 维护）；验证：resty 单测（GRANT 成功/不足/冲突/不确定四分类）+ **不得出现 remaining>granted 与负库存**结构断言
- [ ] 4.5 多 Worker 隔离：A/B 各自 Lease 互不可见互不代管；A 崩溃（table 丢弃）不影响 B；验证：resty 双 VM/分进程验证 + spec（所有权场景）
- [ ] 4.6 组测试报告 + commit `feat: add worker local lease manager`；验证：git log

## Phase 5：Lease 生命周期（`feat: add lease lifecycle and idle return`）

- [ ] 5.1 单调时钟落地（1.2 结论：FFI CLOCK_MONOTONIC 经可注入接口；核查不通过 ⇒ 停止本 Phase 并报告，不得用不合格时钟顶替）；验证：注入时钟单测六件套——正常推进/回拨/前跳/单调推进而墙上不变/idle 触发/max 触发
- [ ] 5.2 每 Worker 扫描器（1s 周期，仅本 Worker ACTIVE Lease）+ `sweeping` 重入保护 + 单 Lease RETURN 失败不影响其他 Lease + 扫描延迟/RETURN 开始时间记录；验证：resty 单测（到期发现/重入保护/失败隔离）
- [ ] 5.3 idle/max 关闭触发（idle_threshold>0 且 idle≥阈值；或 age≥max_lifetime——阈值取 Lease 创建快照）调用统一关闭函数；idle=0 仅 max 生效；验证：resty 注入时钟单测 + spec（生命周期场景）
- [ ] 5.4 RETURN 有限重试策略落地：仅 uncertain（超时/连接中断）原 ID+原 requested 重试，总计 ≤3 次尝试（明确错误不重试；ALREADY_RETURNED=成功终态）；达上限 ⇒ CLOSED + lost；验证：resty 单测（计数/上限/分类）+ E2E CLIENT PAUSE（幂等重试成功且桶只加一次）
- [ ] 5.5 配置快照与隔离 E2E：改 limit ⇒ 新 pool_key 新 Lease；改 idle/max ⇒ 既有 Lease 用旧阈值、新 Lease 用新值；旧 Lease RETURN 校验 pool_key（POOL_MISMATCH 拒绝路径）；验证：spec（配置隔离场景）
- [ ] 5.6 组测试报告 + commit `feat: add lease lifecycle and idle return`；验证：git log

## Phase 6：请求路径集成（`feat: integrate worker lease into rate limit path`）

- [ ] 6.1 `algorithm.lua` 接线：单规则 batch>1 ⇒ TAKE → NEED_GRANT ⇒ GRANT_LEASE → 建本地 Lease/消费 1；granted=0 ⇒ 429；**batch=1 与多规则路径一行不动**；验证：resty 单测 + 三模式行为矩阵
- [ ] 6.2 `handler.lua`：每 Worker 扫描器启动；故障分支接线核对（Redis 不可用 ⇒ 既有 503/降级语义不被 Lease 改变；不得用 Lease 绕过 Fail-close；429/503 语义不混淆）；验证：启动日志 + 故障注入
- [ ] 6.3 SIGTERM best-effort（按 1.3 结论）：可行 ⇒ exiting 轮询触发本 Worker 关闭（不阻塞退出、不重复 RETURN、不做保证性表述）；不可行 ⇒ 报告 NOT RUN + 损失声明；验证：spec 边界
- [ ] 6.4 全量回归：quota.sh（batch=1 基线 100/350/0 + batch=20 区间——锚点变化注明原因）+ dims.sh + rules.sh 全绿；故障双路径；脚本缓存丢失自愈；验证：spec（适用边界三场景 + EVALSHA 零回归）
- [ ] 6.5 并发与异常 E2E：TAKE/关闭/RETURN 交错（场景 A/B/C）；多 Worker 并发 GRANT 全局额度正确；kill -9 确定性账目（granted−consumed−returned_applied=lost）；CLOSING/RETURN 中崩溃 ⇒ 损失方向核验；Worker 异常退出不发生补偿性超发；验证：spec（状态机/所有权/账目场景）
- [ ] 6.6 组测试报告 + commit `feat: integrate worker lease into rate limit path`；验证：git log

## Phase 7：性能测试与报告（`test: add phase4 lease performance report`）

- [ ] 7.1 第三组测试（Lease+EVALSHA）：batch 1/10/50/100（batch=1 为原路径对照）× Worker 1/多 × 速率低中高 × RETURN 开/关 × 不同 idle/max_lifetime × Redis 正常/短暂故障恢复；验证：GRANT/RETURN 次数、granted/consumed/requested/applied/discarded/lost、扫描器延迟、RETURN 失败次数采集齐
- [ ] 7.2 三组对比与结论（§12.5 八问逐项回答：EVALSHA 收益/batch↑ QPS 下降/p99 改善/RETURN 开销/idle-max 与损失/多 Worker 正确性/故障恢复无重复归还/与 batch=1 基线的限流差异）；验证：结论必须同时评估限流语义与库存损失
- [ ] 7.3 报告体例：每项测试含编号/目的/环境/Worker 数/Redis 配置/限流配置/压测参数/实际请求量/时长/RPS/p50/p95/p99/Redis QPS/Redis CPU/Kong CPU/异常/结论；未执行项 NOT RUN；验证：results.md + reports 符合体例
- [ ] 7.4 commit `test: add phase4 lease performance report`；验证：git log

## Phase 8：清理（`refactor: remove legacy local inventory implementation`；仅当全部测试通过）

- [ ] 8.1 删除 `lib/store.lua` 及全部引用、compose 的 `KONG_NGINX_HTTP_LUA_SHARED_DICT` 与相关 docs 段落、重复/不可达代码、过时配置；保留测试与诊断日志；验证：grep 无残留引用 + 启动正常 + 全量回归仍全绿
- [ ] 8.2 README 与配置说明更新（Lease 模式、参数、错误码语义）；验证：文档与实现一致
- [ ] 8.3 commit `refactor: remove legacy local inventory implementation`；验证：git log

## Workflow follow-up

- 全部 Phase 完成且人工验收通过后执行 `openspec archive phase4-performance-and-lease-return`（9 条 ADDED 追加合入主 spec）。
- 遗留输入（Deferred）：GRANT 幂等、Redis Cluster、精确生产总账、Worker 接管、SIGTERM 可靠归还、多规则 β、Lease 清理索引。
