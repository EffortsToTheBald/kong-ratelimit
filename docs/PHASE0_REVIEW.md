# PHASE0_REVIEW —— Phase 4 代码现状审查

> 审查基准：Phase 4 最终实施规范（EVALSHA + Worker 本地 Lease + 幂等归还）。
> 审查方式：逐文件通读 + 容器实测（2026-11-12）。**本报告不修改任何生产代码。**
> HEAD：`e55ff5e` 之后的 Phase 0 提交（Phase 1–3 已归档，master 干净）。

## 1. 当前实现架构

```
HTTP Request → Kong access 阶段（handler.lua，PRIORITY=1002，低于 key-auth 1250）
  → algorithm.build_key(conf)          # 桶键 = kong:rl:{<ns>:p=<指纹>:<dims>}
  → algorithm.check(conf, key)
        ├─ batch 解析：0=auto ⇒ clamp(limit/50, 1, 50)
        ├─ batch>1（fast path）：store.take(key)（ngx.shared.DICT 原子扣减）
        ├─ slow path：redis.grant(conf, key, batch, ttl, rate, burst) —— EVAL TOKEN_BUCKET
        │     granted>1 ⇒ store.fill(key, granted−1)
        └─ granted≤0 ⇒ 429（Retry-After 同口径）
多规则（conf.rules 非空）：redis.grant_multi() —— EVAL GRANT_MULTI（全或无原子）
Redis 故障：fault_tolerant=false ⇒ 503；true ⇒ degraded 放行
```

- 部署：3× Kong 3.6 DB-less（每节点固定 2 workers，compose 注释明确"固定 worker 数让 shared dict 行为可复现"）+ Redis 7 + echo。
- 配置下发：DB-less 逐节点 POST /config；kong.yml 初始 limit=1000/window=60/batch=0(auto=20)。

## 2. 关键代码文件与函数

| 文件 | 关键内容 |
|---|---|
| `kong/plugins/rate-limit-advanced/handler.lua`（109 行） | `init_worker()`：仅 shared-dict 降级告警（D5，Phase 2 产物）；`access()`：build_key → check → 响应头/429/503/降级 |
| `.../lib/algorithm.lua`（411 行） | `build_key()`（指纹 p=+dims；rules 模式组键 g=+r<i>）、`policy_fingerprint()`（FNV-1a）、`resolve_batch()`、`rate_and_burst()`、`check()`（fast/slow 路径）、`check_multi()`、`validate_rules()` |
| `.../lib/redis.lua`（411 行） | `TOKEN_BUCKET`（内嵌）、`GRANT_MULTI`（内嵌）、`grant()`/`grant_multi()`（EVAL 全文上传）、`parse_grant_response()`/`parse_multi_grant_response()` 防御校验、`connect()` 公共连接 |
| `.../lib/store.lua`（87 行） | shared dict `kong_rl` 的 `take()`（incr −1，负回滚+墓碑 TTL 60s）/`fill()`（incr +n + expire）/`backend()` |
| `.../schema.lua` | limit/window/burst/batch/limit_by/header_name/namespace/hide_client_headers/fault_tolerant/redis{host,port,password,database,timeout,key_prefix}；entity_checks（header_name 前置、rules 互斥/batch/上限） |
| `redis/token_bucket.lua`、`redis/multi_bucket.lua` | 独立脚本（Day-1 裸跑/双源同步约定：内嵌脚本与文件 diff 为空） |
| `kong/kong.yml` | 声明式初始配置（插件挂 /echo 路由） |
| `docker-compose.yml` | `KONG_NGINX_HTTP_LUA_SHARED_DICT: "kong_rl 32m"`、`KONG_LOG_LEVEL: notice`、固定 worker 数 |
| 测试 | `bench/quota.sh`（batch=1 恰 100/batch=20 区间）、`bench/dims.sh`、`bench/rules.sh`、`bench/matrix.sh`、`bench/xff.sh`、`k6/quota.js`、`k6/latency.js` |

## 3. 当前 Redis Bucket 字段（实测核对）

```
HGET key tokens → 浮点字符串（如 "97.83…"）
HGET key ts     → 上次补充时间（Redis TIME 秒）
```

- **字段只有 tokens/ts**；rate/capacity **不在 Bucket 中**，由 ARGV 传入（ARGV[1]=rate, ARGV[2]=burst, ARGV[3]=want, ARGV[4]=ttl_ms）。
- 新桶初始化：tokens=burst（满桶），ts=now。
- refill：`elapsed = max(0, now−ts)`（P0-4 时间回拨防护已实现）；`tokens = min(burst, tokens + elapsed×rate)`。
- 部分授予：`granted = min(want, floor(tokens))`；tokens<1 ⇒ granted=0（429）。
- TTL：`max(1, floor(window×2))×1000` PEXPIRE。

**与规范 §3.1 对照**：tokens ✓、last_refill_time=ts ✓；rate/capacity 采用 **ARGV 统一传递方案**（规范允许，且同 pool_key ⇒ 同指纹 ⇒ 同 rate/capacity 可证明一致）。GRANT_LEASE/RETURN_LEASE 必须沿用同一 ARGV 方案（tasks 3.1/3.2 已写入）。

## 4. 当前 rate/capacity 来源与 TTL 策略

- rate = conf.limit / conf.window；capacity = conf.burst>0 ? conf.burst : conf.limit（`rate_and_burst()`）。
- TTL = 2×window（桶状态清理周期，非 refill 周期）。
- **三个脚本（现两个）refill 语义一致**（同一公式同构）；新增 GRANT_LEASE/RETURN_LEASE 必须保持同构并通过相同测试向量（tasks 3.5）。

## 5. 当前 EVAL 调用路径

- `redis.lua` 内嵌脚本文本 + `r:eval(SCRIPT, n, keys..., argv...)`——**每次全量上传**（Phase 2 要解决的问题）。
- 无 SCRIPT LOAD/EVALSHA/SHA 缓存；无脚本表。
- 防御校验（Phase 2 D3 手法）：`parse_grant_response`/`parse_multi_grant_response` 纯函数，畸形 ⇒ close 连接进故障分支。

## 6. 当前多规则原子性实现

- `GRANT_MULTI`：KEYS=各规则桶键（组内同 hash tag），单脚本内"全检-全扣/全不扣"，返回不足规则；已验证（Phase 3，rules.sh 14 断言）。
- 组键 `kong:rl:{<ns>:g=<组指纹>:r<i>:<dims>}`；规范 §1.1"多规则保持原逻辑" ⇒ **一行不动**。

## 7. 与本规范的差异清单

| # | 规范要求 | 现状 | 差异/动作 |
|---|---|---|---|
| 1 | EVALSHA + NOSCRIPT 自愈 | EVAL 全文上传 | Phase 2 实现（脚本表/LOAD/重试一次/超时≠NOSCRIPT） |
| 2 | 四脚本统一管理 | 两脚本（TOKEN_BUCKET/GRANT_MULTI） | 新增 GRANT_LEASE/RETURN_LEASE（Phase 3） |
| 3 | 单规则 batch>1 用独立 Lease | store.lua 聚合库存（shared dict） | **整体替换**（Phase 4/6），store.lua 在 Phase 8 删除 |
| 4 | Lease Redis 记录（OPEN/RETURNED、return_requested） | 无 | Phase 3 新建 lease:{lease_id} |
| 5 | RETURN 幂等提交点（先标记后桶） | 无 | Phase 3 实现（规范 §5.2 顺序，运行时不回滚论证） |
| 6 | RETURN 错误码体系 | 无 | Phase 3 实现（九类错误码） |
| 7 | Worker 本地 Lease table/状态机 | 无（聚合库存） | Phase 4 实现 |
| 8 | 每 Worker 扫描器/idle/max_lifetime | 无（仅 init_worker 告警） | Phase 5 实现；shared-dict 告警随 Phase 8 清理 |
| 9 | 真单调时钟 | **不存在**——现状无本地时钟使用（store 无时间戳），Phase 5 需要 | Phase 0/1.2 核查 FFI CLOCK_MONOTONIC；不可行 ⇒ 停止 Phase 5 并报告 |
| 10 | 配置快照进 Lease | 无 | Phase 4 lease 对象携带创建时 idle/max |
| 11 | 指标口径（lease_*） | 仅 RL-DEBUG 日志 | Phase 6/7 以 Worker 计数器+日志落地（Prometheus 留后续） |
| 12 | 性能矩阵三组 | matrix.sh 有 batch×RPS 骨架 | Phase 1/2/7 扩展维度（batch 10/50/100、CPU、命令分类） |

## 8. 兼容性影响

1. **batch>1 路径整体重写**：Phase 1/2 的锚点——quota.sh batch=20 区间 [40,100]（3 节点少发上界 3×batch）——Lease 模型下少发上界仍为 Σ(每 Worker 未关闭 remaining) ≈ 每节点 batch×Worker 数，区间语义兼容但边界值可能变化 ⇒ 报告注明，不改测试预期。
2. **store.lua 删除**（Phase 8）：compose 的 shared dict 注入与本插件解耦；其他插件未使用该 dict（kong_rl 为本项目专用命名）⇒ 删除安全，但需全量回归确认。
3. **shared-dict 降级告警删除**：handler init_worker 的 D5 告警失去对象 ⇒ Phase 6 移除。
4. **batch=1 与多规则路径零改动**：quota batch=1 基线/dims/rules 直接作为回归防线。
5. **Redis Key 新增 lease:{lease_id}**：与既有桶键无冲突；规范要求遵循现有 Key 规范 ⇒ 采用 `kong:rl:lease:{lease_id}`（前缀一致，standalone 无 slot 约束；Cluster 前提已在 Design Deferred 声明）。

## 9. 实施风险

1. **单调时钟（最高风险）**：环境无原生 API 时需 LuaJIT FFI 直调 `clock_gettime`——ABI/兼容性必须 Phase 0/1.2 实测；不通过 ⇒ **停止 Phase 5**（规范 §7.5 允许并要求报告，不悄悄降级）。
2. **RETURN 幂等提交点顺序**是本阶段最容易写反的点（"先加桶后标记"看似直观但会重复归还）——tasks 3.2 有专项矩阵测试钉死。
3. **GRANT 超时不重试**与既有故障分支的衔接：超时 ⇒ 故障分支（503/降级），用户感知与"Redis 不可用"一致；需在 Phase 6 验证。
4. ** Lease 记录数量** = GRANT 次数（TTL 有界）——高流量下 Redis 内存占用需在 Phase 7 观测（报告项）。
5. **性能矩阵规模**（三组 × 多维度）耗时较长——NOT RUN 机制兜底，逐项如实标注。
6. **无阻塞项**：规范与现有代码未发现不可兼容冲突；Phase 1 可开始。

## 10. 需修改的文件清单（汇总）

| Phase | 文件 | 动作 |
|---|---|---|
| 2 | `lib/redis.lua` | 脚本表（4 脚本）+ EVALSHA 包装 + 错误类别透传 |
| 3 | `redis/grant_lease.lua`、`redis/return_lease.lua`（新）+ `lib/redis.lua` | 双源脚本 + 调用封装 |
| 4 | `lib/lease.lua`（新） | Worker 级 Lease table/TAKE/状态机/关闭/GRANT 调用 |
| 5 | `lib/lease.lua` | 扫描器/单调时钟/重试/配置快照 |
| 6 | `lib/algorithm.lua`、`handler.lua`、`schema.lua` | 接线/扫描器启动/两个生命周期配置/移除 shared-dict 告警 |
| 7 | `bench/matrix.sh`、`bench/results.md` | 第三组维度与报告 |
| 8 | `lib/store.lua`、`docker-compose.yml`、README/docs | 删除聚合实现与 shared dict、文档同步 |

## 11. Phase 1 具体执行计划

1. 环境自检（compose 5 容器 running/healthy）+ 基线 commit（`--allow-empty` 锚点）。
2. 首日事实核查：FFI `clock_gettime(CLOCK_MONOTONIC)`（ABI/返回值/错误处理/容器内实测）；`CLIENT PAUSE`；Worker 级模块 table 隔离实证（两 worker 独立 VM）。**FFI 核查不通过 ⇒ 报告并暂停 Phase 5 相关设计确认（不阻塞 Phase 1/2）**。
3. `matrix.sh` 扩展第一组维度（batch 1/10/50/100、速率低中高、Worker 1/多、单/多规则、Redis CPU、Kong CPU、commandstats 分类）。
4. 执行 EVAL 基线 → `bench/results.md` 基线段 + 原始数据保存（bench/out/）。
5. commit `test: add phase4 eval performance baseline`。
