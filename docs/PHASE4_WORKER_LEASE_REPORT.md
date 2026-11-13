# Phase 4 组测试报告：Worker 本地 Lease（任务 4.1–4.6）

- **日期**：2026-11-13
- **HEAD 基线**：`089e588`（V1 design 措辞修正后）
- **任务组**：tasks.md Phase 4（实施规范 Phase 4：Worker 本地 Lease，不接请求路径、不接扫描器，先单测）
- **commit**：`feat: add worker local lease manager`

## 1. 实施范围

| 任务 | 内容 | 状态 |
|---|---|---|
| 4.1 | `lib/lease.lua` Worker 级模块表：pools/leases 结构、lease 对象七字段、守恒不变量 | 完成 |
| 4.2 | TAKE 非 yield 同步片段：查 ACTIVE→递减→ALLOW / NEED_GRANT；yield 探针 | 完成 |
| 4.3 | 耗尽处理（V1 简化）：remaining=0 ⇒ CLOSED/摘除可消费集合/保留诊断；无 RETURN 无快照 | 完成 |
| 4.4 | GRANT 调用接线：lease_id 生成、四分类、多 Lease 并存（追加不覆盖）、结构断言 | 完成 |
| 4.5 | 多 Worker 隔离：双 resty 进程（=双 VM）验证互不可见/互不代管/进程内单例 | 完成 |
| 4.6 | 组测试报告 + commit | 完成 |

**明确未做（范围外确认）**：`algorithm.lua`/`handler.lua`/`schema.lua`/`store.lua` 一行未动（请求路径集成属 Phase 6）；Phase 5 生命周期内容零触碰；`lib/redis.lua` 仅**纯新增** `grant_lease()` 调用函数（Phase 3 已注册脚本，无调用方），既有 `grant`/`grant_multi`/evalsha 路径未改动。

## 2. 修改文件清单

| 文件 | 变更 | 原因 |
|---|---|---|
| `kong/plugins/rate-limit-advanced/lib/lease.lua` | **新增** | 任务 4.1–4.4：Worker 本地 Lease 管理器 |
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | 纯新增 `_M.grant_lease()`（+36 行） | 任务 4.4：GRANT_LEASE 调用传输层（复用 connect/evalsha/parse_grant_response） |
| `test/lease-unit.lua` + `test/lease-unit.sh` | **新增** | 任务 4.1–4.4 resty 单测（25 断言） |
| `test/lease-iso.lua` + `test/lease-isolation.sh` | **新增** | 任务 4.5 双 VM 隔离验证（7 断言） |
| `test/lease-grant-smoke.lua` + `test/lease-grant-smoke.sh` | **新增** | 任务 4.4 真链路 smoke（11 断言，含 CLIENT PAUSE 构造） |
| `openspec/changes/.../tasks.md` | 4.1–4.6 勾选 | 任务完成标记 |

## 3. 核心实现说明

### 3.1 数据结构（design D2 冻结结构）
- `pools[pool_key] = { leases = {...}(全量诊断，只增不删), active = {...}(可消费集合，插入序) }`
- lease 对象：`lease_id / pool_key / granted / remaining / consumed / created_at / state`
- **字段名说明**：tasks.md 4.1 写 `status`，design.md D2 冻结为 `state`（"ACTIVE"|"CLOSED"）。实现依据 = design.md ⇒ 采用 `state`（Redis 侧记录字段仍为 `status`，与 Phase 3 Lua 一致）。

### 3.2 TAKE 原子性（D2/D3）
- 查找/检查/递减/（耗尽时 CLOSED 标记+摘除）在同一非 yield 片段完成；协程探针断言：单次 `coroutine.resume` 内跑完（status=dead）⇒ 片段内无 yield。
- 耗尽 ⇒ `state="CLOSED"` + `table.remove(active)`；对象保留于 `leases` 仅作诊断；CLOSED 不可复活（active 集合中不存在 ⇒ TAKE 不选中）。
- 无 Redis 访问、无等待、无补偿路径（结构断言由 `invariants()` 承载）。

### 3.3 GRANT 四分类（D4）
- `success`（granted≥1 ⇒ 登记）/ `insufficient`（granted=0 ⇒ 429 语义，不登记）/ `explicit_error`（LEASE_EXISTS / INVALID_ARGUMENT / 脚本装载失败——确定未执行零写入）/ `uncertain`（超时/断开/畸形——可能已执行 ⇒ **不重试、不登记**，允许损失）。
- lease_id：`<hostname>:<worker>:<进程内单调计数器>:<随机 hex>`；1000 个生成唯一性断言通过。

### 3.4 守恒与账目（D8）
- 结构不变量函数 `invariants()`：`remaining+consumed=granted`、`0≤remaining≤granted`、`state∈{ACTIVE,CLOSED}`、CLOSED⇒remaining=0、active 集合无重复/无非可消费对象、计数器无漂移；随机 100 次操作序列断言通过。
- V1 账目恒等式 `granted = consumed + outstanding`（无丢失序列）断言通过（100/80/20/0）。

## 4. 测试矩阵与实际结果

| 测试 | 命令 | 结果 |
|---|---|---|
| lease 单测（25 断言：结构/守恒/TAKE/插入序/共存/yield 探针/耗尽 CLOSED/四分类/不重试不登记/lease_id 唯一/账目恒等式） | `bash test/lease-unit.sh` | **PASS 25/25** |
| 多 Worker 隔离（双进程双 VM：互不可见/TAKE 只取自有/进程内单例） | `bash test/lease-isolation.sh` | **PASS 7/7** |
| GRANT 真链路 smoke（真 EVALSHA 授予+Redis 记录/扣桶证据；CLIENT PAUSE 超时 ⇒ uncertain 不重试不登记 + Redis 侧零写入实证） | `bash test/lease-grant-smoke.sh` | **PASS 11/11** |
| Phase 2 evalsha 单测回归 | `bash test/evalsha-unit.sh` | **PASS 8/8** |
| Phase 3 Lease 裸跑矩阵回归（串行复跑） | `bash test/lease-redis-matrix.sh` | **PASS 50/50** |
| Phase 1 quota 回归 batch=1（严格 100/350/0） | `bash bench/quota.sh -l 100 -b 1 -p 150` | **PASS** |
| Phase 1 quota 回归 batch=20（区间 [40,100]） | `bash bench/quota.sh -l 100 -b 20 -p 150` | **PASS**（利用率 100%，少发 0） |
| Phase 2 dims 回归 | `bash bench/dims.sh` | **PASS 8/8** |
| Phase 3 rules 回归 | `bash bench/rules.sh` | **PASS 14/14** |
| Phase 7 性能三点 / kill -9 损失核验 / Phase 6 请求路径集成 | — | **NOT RUN**（属 Phase 6/7 任务，本组范围外） |

## 5. 实施期发现与处置

| # | 发现 | 处置 |
|---|---|---|
| 1 | **LuaJIT `math.random` 跨 VM 确定性碰撞**：不播种时每个新 VM 输出相同序列 ⇒ 同 host+worker+计数器起点的 lease_id 跨重启完全相同；实测 GRANT 撞上残留记录返回 `LEASE_EXISTS`（Redis 兜底按冻结决策正确拒绝，零覆盖） | `lib/lease.lua` 每 VM 首次生成前播种（毫秒时间+Worker PID 熵源）；唯一性断言重跑通过。D4"生成规则使冲突概率≈0"得以成立 |
| 2 | **测试基建并行干扰（既有约束，非本次引入）**：`bench/rules.sh`/`bench/dims.sh` 场景间 `FLUSHDB`，与 Phase 3 矩阵并行运行会清掉矩阵预置桶状态 ⇒ 首轮并行出现 5 FAIL、三轮中单独复跑 50/50 | 所有回归改为**串行**执行；矩阵单独复跑 **50/50 PASS**（首轮失败项未逐项留痕，如实记录为并行 FLUSHDB 干扰） |
| 3 | **CLIENT PAUSE + 客户端超时的实证语义**：客户端读超时 ⇒ OpenResty cosocket 关闭连接 ⇒ Redis 对已断开连接的排队 EVALSHA **不再执行**（实测 pause 过期后桶未被扣、无 Lease 记录 ⇒ 该构造下零写入）。design Context 事实 5 的"已执行但响应丢失"构造在 resty 传输层下不成立——除非脚本执行中（非排队中）超时 | smoke 断言按实证结果如实收敛（`pause-not-executed-*`）；分类层保持保守（不重试/不登记）不变；"脚本执行中超时⇒已执行损失"分支无法用冻结脚本构造，NOT RUN 记入已知限制 |

## 6. 与冻结决策的对照

- batch=1 严格路径：未触碰（quota.sh 复跑一致）✓
- 多规则 GRANT_MULTI：未触碰（rules.sh 全绿）✓
- 多 Lease 并存/追加不覆盖/TAKE 插入序：单测+grant smoke 断言 ✓
- 耗尽 CLOSED/摘除/保留诊断/无 RETURN：单测断言 ✓
- GRANT 超时不重试不登记：单测 + CLIENT PAUSE smoke 断言 ✓
- Worker 隔离/无接管：双 VM 验证 ✓
- Fail-close/429/Retry-After 语义：本组未接请求路径，Phase 6 核对（NOT RUN）

## 7. 已知限制

1. V1 无库存回收：CLOSED Lease 对象与 Redis OPEN 记录随进程/TTL 生命周期留存（冻结决策，Phase 5 恢复时引入 RETURN/清理）。
2. `pool.active` 为插入序线性扫描，单 Worker 生命周期内 GRANT 总量为上界（Phase 7 batch=10 性能实测覆盖）。
3. "脚本执行中超时 ⇒ 已执行损失"分支无确定性 E2E（见发现 #3）。
