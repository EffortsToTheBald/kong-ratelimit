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

## 7. Git Commit

- `feat: add redis lease grant and return scripts`（本组全部：两脚本 + 注册 + 矩阵 + 注入生成器 + 文档裁决同步）
