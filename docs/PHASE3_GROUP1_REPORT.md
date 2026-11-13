# Phase 3 第一组（Redis Lease 数据模型）实施报告

> 对应实施规范 Phase 3（tasks 组 3）；授权范围：GRANT_LEASE/RETURN_LEASE 双源 + 注册 + 裸跑矩阵 + TTL + refill 向量 + 幂等故障注入。**未接请求路径**。

## 1. 修改文件

| 文件 | 动作 |
|---|---|
| `redis/grant_lease.lua` | 新增（独立裸跑脚本，含用法注释） |
| `redis/return_lease.lua` | 新增（独立裸跑脚本，含写顺序铁律注释） |
| `lib/redis.lua` | 注册 GRANT_LEASE/RETURN_LEASE 到统一脚本管理器（内嵌双源 src；**调用封装函数留 Phase 4**） |
| `test/lease-redis-matrix.sh` | 新增（27 断言裸跑矩阵） |
| `test/make_inject_variant.py` | 新增（提交点后失败注入的测试变体生成器，**生产脚本不动**） |
| `openspec/.../{proposal,design,tasks}.md` | 三项裁决定点同步（lease key/idle_threshold/阶段映射） |

## 2. 核心实现

- **GRANT_LEASE**（KEYS[1]=桶、KEYS[2]=`kong:rl:lease:{lease_id}`；ARGV=[batch,lease_ttl_ms,lease_id,pool_key,rate,capacity,bucket_ttl_ms]）：三阶段（参数校验零写入 → EXISTS ⇒ LEASE_EXISTS / 桶类型与字段校验 → refill(elapsed=max(0,now−ts)) → granted=min(batch,floor(tokens)) → tokens<1 ⇒ granted=0 **不建记录不扣桶** → 扣桶 + HSET lease(status=OPEN,granted,pool_key,created_at=Redis TIME) + PEXPIRE×2）。
- **RETURN_LEASE**（KEYS[1]=lease、KEYS[2]=桶；ARGV=[requested,pool_key,bucket_ttl_ms,rate,capacity]）：阶段 0 参数（requested 非负整数 <2^53，小数 1.5 拒）→ 阶段 1 只读（LEASE_NOT_FOUND/ALREADY_RETURNED vs RETURN_CONFLICT（读 return_requested 比对）/INVALID_LEASE_STATE/POOL_MISMATCH/INVALID_REQUESTED/BUCKET_NOT_FOUND/桶字段非法——均零写入）→ 阶段 2 写：**【幂等提交点】先 HSET lease(status=RETURNED,return_requested=requested)** → requested>0 ⇒ refill→+requested→capacity 封顶 ⇒ **一次 HSET 完整桶状态**+TTL → 返回 {requested,applied,discarded}；requested=0 跳过桶更新仍完成转换；**RETURN 不重设 Lease TTL**（RETURNED 保留至原 TTL = 幂等保护窗口）。
- **错误分类前置**：所有校验在任何写之前（Redis Lua 运行时错误不回滚）；错误码九类与 Spec 一致。
- **Key 裁决落地**：`kong:rl:lease:{lease_id}`；**Cluster Slot 一致性不在本阶段保证范围**（已记录）。

## 3. 测试命令与结果

```bash
./test/lease-redis-matrix.sh        # 27 断言裸跑矩阵（真实 Redis）
./test/evalsha-unit.sh              # Phase 2 回归（8/8）
./test/lease-redis-matrix.sh 双源 diff  # sed 提取内嵌 vs 独立文件
```

| 测试 | 类型 | 结果 |
|---|---|---|
| GRANT：正常授予（granted=5/桶95/OPEN/字段） | 真 Redis | PASS |
| GRANT：部分授予 floor(2.5)=2 | 真 Redis | PASS |
| GRANT：tokens<1 ⇒ granted=0 不建记录桶不变 | 真 Redis | PASS |
| GRANT：LEASE_EXISTS（同 ID） | 真 Redis | PASS |
| GRANT：参数非法（batch=0/1.5、rate=−1）零写入 | 真 Redis | PASS |
| GRANT：桶字段非法（tokens=abc）零写入 | 真 Redis | PASS |
| GRANT：Lease TTL PTTL ∈ [55000,60000]（传入 60000） | 真 Redis | PASS |
| RETURN：正常归还（applied=5、桶 95→100、RETURNED、rr=5） | 真 Redis | PASS |
| RETURN：同参幂等（桶不变） | 真 Redis | PASS |
| RETURN：异参 RETURN_CONFLICT | 真 Redis | PASS |
| RETURN：requested=0 转状态（桶不变） | 真 Redis | PASS |
| RETURN：requested>granted 零写入 | 真 Redis | PASS |
| RETURN：POOL_MISMATCH 零写入 | 真 Redis | PASS |
| RETURN：Lease 过期 ⇒ LEASE_NOT_FOUND | 真 Redis | PASS |
| RETURN：Bucket 不存在 ⇒ BUCKET_NOT_FOUND 不建桶 | 真 Redis | PASS |
| RETURN：requested=1.5 小数零写入 | 真 Redis | PASS |
| RETURN：并发两 RETURN（一成功一 ALREADY_RETURNED、桶只加一次） | 真 Redis | PASS |
| 注入：提交点后失败（RETURNED 已定、桶未加） | 真 Redis（测试变体） | PASS |
| 注入：同参重试 ALREADY_RETURNED 桶不增 | 真 Redis | PASS |
| refill 向量：四脚本同状态同向量 | 真 Redis | PASS |
| refill 归一化一致性（四脚本偏差 <3s） | 真 Redis | PASS |
| 双源 diff ×4（TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE） | 静态 | PASS |
| Phase 2 回归：evalsha 单测 8/8、quota/dims/rules（未重跑，本组未接请求路径，Lua 脚本新增不改变既有调用） | — | NOT RUN（Phase 4 集成后强制重跑） |

**汇总：PASS=27 FAIL=0**（`test/lease-redis-matrix.sh` rc=0）。

## 4. 关键测试证据

1. **幂等提交点顺序**：注入变体（提交点后 `return redis.error_reply("INJECTED_FAILURE")`）⇒ Lease status=RETURNED 已定、桶 tokens 不变；生产脚本同参重试 ⇒ ALREADY_RETURNED、桶不增——**"先标记后桶"的失败安全行为实证**。
2. **并发单增**：两 redis-cli 并发 RETURN ⇒ 一 SUCCESS(applied=5) 一 ALREADY_RETURNED、桶 95→100 恰一次。
3. **TTL 边界**：mexp（TTL=100ms）过期 ⇒ LEASE_NOT_FOUND 零写入；正常 Lease PTTL ∈ [55000,60000]。

## 5. 本组实现期发现（测试脚本自身的缺陷，非实现缺陷）

| # | 发现 | 处置 |
|---|---|---|
| 1 | 裸跑矩阵各 case 的 lease key 必须**完整**（`kong:rl:lease:mX`）——早期调用传裸 ID（m1/m2/...）导致跨 case LEASE_EXISTS 污染 | 已修（全部调用传完整 key） |
| 2 | `fresh` 未参数化（只删 m1）⇒ 各 case key 无隔离 | 已修（fresh <lease_key>） |
| 3 | 非 TTL-case 的 Lease TTL=5000ms 在宿主机环境抖动（4-5s，Phase 1 发现 3）下**真实过期** ⇒ LEASE_NOT_FOUND 误报 | 已修（非过期 case TTL=60000；mexp 保留 100ms） |
| 4 | `cat|head`/`local a=$1 b=${a}`/pipefail+SIGPIPE 等 bash 陷阱 | 已修（awk 内退出/拆分赋值） |
| 5 | refill 向量断言公式未扣 granted ±1、容差未含 docker exec 间隔 | 已修（向量期望 109/111/109/109 + 归一化一致性断言） |
| 6 | `docker cp` 不认 compose service 名（需完整容器名）；`dexec $RC` 双层 exec | 已修 |

## 6. 尚未解决的问题

1. `lib/redis.lua` 中 GRANT_LEASE/RETURN_LEASE 的**调用封装**（conf→ARGV 组装、错误分类）留 Phase 4（按授权未实现）。
2. 生命周期参数（lease_return_idle/lease_max_lifetime）schema 未加（Phase 5）。
3. 单调时钟核查（Phase 5 前置强制项）未执行。
4. Cluster Slot 一致性不承诺（Deferred，已在 Design 记录）。

## 7. Phase 3 第一组审查修复（2026-11-13，第二轮）

> 审查（基于 d30592b）结论：FAIL——3 项 P1 待修。

| 问题 | 修复 | 测试 |
|---|---|---|
| **P1-1** GRANT_LEASE wait 在扣减前计算（与接口契约不符） | 顺序修正：granted 判定 → tokens 扣减 → wait=按扣减后 tokens 计算 → 写回 → 返回；双源同步 | 真集成：tokens=2.5/batch=5/rate=0.016 ⇒ 从 Redis 返回值分别解析 granted=2、tokens≈0.5、wait≈31.25（误差区间断言，非字符串比对） |
| **P1-2** TTL 参数校验缺有限性与 2^53 上界（inf/1e20 可穿透 floor 比较） | `is_valid_ttl`：有限数值+正整数+≥1+<2^53；统一应用于 GRANT_LEASE lease_ttl_ms/bucket_ttl_ms 与 RETURN_LEASE bucket_ttl_ms；全部在任何写之前 | 真集成 11 断言：0/−1/1.5/1e20 × 三参数；非法 ⇒ INVALID_ARGUMENT 零写入（桶未扣/Lease 未建/Lease 仍 OPEN 无"已标 RETURNED 后续失败"中间态） |
| **P1-3** 矩阵 wait 测试段缺陷（report 参数/续行/R 未重新执行） | 测试段重写：独立 fresh+HSET 预置、真实部分授予、从返回值 sed 解析三字段、awk 数值断言（granted==2、tokens∈[0.5,0.5]、wait∈[31.2,31.3]） | 真集成 PASS（真值 wait=31.25） |

**Design 同步**：TTL 校验规则（`is_valid_ttl` 语义）已记录于 D4（refill 持久化语义段）。

### 第二轮修复后测试结果

- `test/lease-redis-matrix.sh`：**PASS=50 FAIL=0**（矩阵 39 + wait 契约 1 + TTL 非法 11 − 原有重叠）
- `test/evalsha-unit.sh`（Phase 2 回归）：**PASS 8/8**
- 双源 diff ×4：**PASS**
- 原始输出：`bench/raw/phase1/lease-redis-matrix-final.txt` / `-full.txt`
- quota/dims/rules：**NOT RUN**（Phase 6 集成阶段强制重跑）

### 第二轮实现期发现（测试脚本自身）

1. 1e20 断言最初 grep '1e+20' 与 Redis 错误串不符（错误串回显原始 ARGV 字符串）——断言已改为精确原串；**脚本拒绝行为本身正确**（真集成确认 INVALID_ARGUMENT 返回）。
2. 编辑过程残留孤儿行一次——已清理（矩阵脚本最终版经 `bash -n` 与完整执行验证）。

## 8. Git Commit

> 审查（基于 d53f3f0）结论：核心原子性与幂等提交顺序符合设计，4 项需修复/补验。

| 问题 | 修复 | 测试 |
|---|---|---|
| **P1-1** GRANT_LEASE 不足分支未持久化 refill | 单键脚本与 TOKEN_BUCKET 同构：**不足分支同样写回 refill 后 tokens/ts 并更新桶 TTL**；GRANT_MULTI 保持"不足不写"（多键全或无语义所需，结构差异如实记录） | 真集成 4 断言：granted=0/无记录/ts 只前进/桶 TTL 写回/统一语义 |
| **P1-2** 桶状态数值范围校验缺失 | GRANT_LEASE/RETURN_LEASE 阶段 1 补齐：tokens∈[0,capacity]、ts≥0、有限数值（NaN/±inf 拒）、granted 正整数 <2^53——**非法拒绝且数据不变（不静默修正）** | 真集成 8 断言：负 tokens/超 capacity/负 ts × GRANT/RETURN + granted 非法 ×2 |
| **P1-3** wait 返回语义未定义 | 与 TOKEN_BUCKET 契约统一：按**扣减后** tokens 计算（部分授予 wait>0） | 部分授予（tokens=2.5/batch=5/rate=0.016）：granted=2、剩 0.5、wait=31.25s 精确断言 |
| **P2-4** Lease Key 占位符歧义 | design.md 注明 `kong:rl:lease:{lease_id}` 中 `{...}` 为占位符非 Hash Tag，实际 Key 无大括号（裸跑矩阵与实现一致）；Cluster Slot 一致性属 Deferred | 静态核对 |

**TOKEN_BUCKET/GRANT_MULTI 的历史差异说明**：两脚本仅有 tonumber 级校验（无范围检查），属 Phase 1/3 已验收路径——按"不顺带扩大重构"原则**不修改**，差异记录于此（其输入由既有调用方 conf 推导，风险受控）。

### 修复后测试结果

- `test/lease-redis-matrix.sh`：**PASS=39 FAIL=0**（含新增 12 断言：不足分支持久化 ×4、wait 契约 ×1、范围校验 ×8）
- `test/evalsha-unit.sh`（Phase 2 回归）：**PASS 8/8**
- 双源 diff ×4：**PASS**
- quota/dims/rules：**NOT RUN**（本组未接请求路径，Phase 6 集成阶段强制重跑）

### 修复过程中的测试脚本自身缺陷记录（均为矩阵脚本问题，生产脚本零缺陷）

1. redis-cli TIME 输出两行（秒+微秒），裸 `awk '{print $1}'` 输出两行 ⇒ 预置 ts 两行 ⇒ grant 读 ts 校验拒——全部 TIME 读取补 `NR==1`。
2. `$(( $RC TIME ... ))` 双括号=算术展开（set -u 报变量未绑定）——已改单括号 `$()`。
3. 部分授予/tokens<1 case 的 HSET 在 fresh（DEL 桶）之前执行被删——统一 fresh 在前、预置在后。
4. multi_bucket 调用 ARGV 多传一参（ttl=1ms 桶秒过期）——已修。
5. requested=0 测试场景误置 granted=0（与 P1-2 的 granted≥1 校验冲突）——改为 granted≥1 + requested=0（spec 语义：requested=0 表示全消费，granted 本身 ≥1）。
6. `dexec $RC` 双层 exec、docker cp 用 service 名报错——已修（完整容器名）。

## 8. Git Commit

- 第一组：`feat: add redis lease grant and return scripts`
- 第一轮修复：`fix: phase3 group1 review fixes (refill persistence, validation, wait contract)`
- 第二轮修复：`fix: phase3 group1 round2 (wait order, ttl validation bounds, wait test rewrite)`

## 9. 尚未解决的问题

同第一组报告 §6（调用封装 Phase 4、schema 生命周期参数 Phase 5、单调时钟核查 Phase 5 前置、Cluster Deferred）。无新增。

- `feat: add redis lease grant and return scripts`（本组全部：两脚本 + 注册 + 矩阵 + 注入生成器 + 文档裁决同步）
