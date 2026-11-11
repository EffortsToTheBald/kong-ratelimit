# 架构图与实现状态

> 配套文档：`docs/design.md`（设计取舍与误差分析）、`reports/phase-1-correctness.md`（验收证据）、`test/first-commit.md`（人工剧本）。
> 图示约定：**实线** = 已实现并验证（Phase 1）；**虚线框** = 计划中/未实现（对应 change 或 Phase 4/5）。

## 1. 总体架构（部署拓扑 + 单节点内部）

```mermaid
flowchart TB
    C["客户端 / k6<br/>无前置 LB · 端口直连<br/>8030 / 8010 / 8020"]

    subgraph NODE["Kong 节点 ×3（DB-less · 每节点 2 worker · kong_rl 32m shared dict）"]
        direction LR
        H["handler.lua<br/>access · PRIORITY 1002<br/>(key-auth 1250 先执行)"]
        ALGO["algorithm.lua<br/>7 维取值 dim_value<br/>FNV-1a 策略指纹进 hash tag<br/>batch=1 短路 / batch=N 租赁"]
        STORE[("store.lua · 本地库存<br/>ngx.shared.kong_rl 跨 worker 共享<br/>incr 原子扣减 · 负值回滚+60s 墓碑")]
        RLUA["redis.lua<br/>keepalive 连接池<br/>EVAL 内嵌令牌桶脚本"]
        H --> ALGO
        ALGO -->|"库存可用"| STORE
        ALGO -->|"库存不足"| RLUA
        RLUA -->|"granted>1 → fill 其余"| STORE
    end

    REDIS[("Redis 7 · 单实例（6380→6379）<br/>全局桶 H tokens/ts<br/>TIME 单调 · burst 封顶 · 部分授予<br/>PEXPIRE 2×window")]
    UP["上游 http-echo :5678"]
    ADMIN["Admin API :8031/8011/8021<br/>POST /config 逐节点下发"]

    C --> NODE
    RLUA <--> REDIS
    NODE -->|"放行 200"| UP
    NODE -->|"429 / 503·degraded"| C
    ADMIN -.声明式配置.-> NODE

    classDef edge fill:#f8f8f2,stroke:#999,stroke-dasharray: 4 3;
    class ADMIN edge;
```

**核心不变量**：全局配额唯一权威在 Redis；本地库存只能来自 Redis 已授权的批量租约 ⇒ **只少发、不超发**，少发上界 ≈ 节点数 × batch。
**Key 格式**：`kong:rl:{<ns>:p=<FNV-1a 指纹>:<dim>=<val>:…}`——策略一变即新桶，旧桶/旧库存随 TTL 淘汰。

## 2. 单请求决策流程

```mermaid
flowchart TD
    REQ["请求进入 access 阶段"] --> BK["build_key<br/>7 维取值 + 策略指纹"]
    BK --> B1{"batch = 1 ?"}
    B1 -->|"是（严格全局）"| EVAL2["每请求必经 Redis EVAL"]
    B1 -->|"否（batch=N）"| TAKE{"store.take(key)<br/>本地库存扣减"}
    TAKE -->|"成功"| ALLOW["放行 200<br/>X-RateLimit-*（本节点视角）"]
    TAKE -->|"失败"| EVAL["Redis EVAL 令牌桶<br/>want=batch"]
    EVAL2 --> RES{"返回 granted"}
    EVAL --> RES
    RES -->|">0"| FILL["本次消耗 1 个<br/>其余 fill 进本地池"]
    FILL --> ALLOW
    RES -->|"=0"| R429["429<br/>Retry-After=wait（暂无上限，见状态表）"]
    RES -->|"nil / err / 畸形"| FT{"fault_tolerant ?"}
    FT -->|"true（显式选择）"| DEG["放行 + X-RateLimit-Status: degraded"]
    FT -->|"false（默认）"| R503["503 rate limiter unavailable"]
```

## 3. 实现状态总览

```mermaid
flowchart LR
    subgraph DONE["✅ 已实现并验证（Phase 1 · commit 3d06fdf..41b10f9）"]
        direction TB
        d1["令牌桶：Redis TIME · ts 单调不回退<br/>burst 封顶 · 部分授予"]
        d2["策略指纹 key：FNV-1a 进 hash tag<br/>配置变更即新桶（实测 116→100）"]
        d3["batch=1 严格短路 / batch=N 租赁<br/>不超发，少发上界 N×batch"]
        d4["本地库存：shared dict 原子扣减<br/>守恒核算通过"]
        d5["默认 fail-closed 503<br/>显式容错 degraded · 无 500/traceback"]
        d6["验证设施：每节点断言<br/>namespace 隔离 · XFF 回归 · 指纹性质 10 断言"]
    end

    subgraph YELLOW["🟡 已实现代码、验证缺位（change: phase2-dimensions-and-semantics 已规划未实施）"]
        direction TB
        y1["多维限流：dim_value 7 维均已编码<br/>但仅 ip 维实测过"]
        y2["X-RateLimit-Reset 语义<br/>现为伪窗口 now+window"]
        y3["Retry-After 上限（现无界）"]
        y4["429 判定日志（现缺失）"]
        y5["header_name 前置校验<br/>（现仅运行时 500）"]
        y6["Redis 返回值防御校验"]
        y7["shared dict 降级启动告警（backend() 未被调用）"]
    end

    subgraph TODO["❌ 未实现（Phase 4/5 与明确不做）"]
        direction TB
        t1["EVALSHA + NOSCRIPT（现每次传全量脚本文本）"]
        t2["Prometheus 指标"]
        t3["结构化日志（RL-DEBUG 为临时态）"]
        t4["本地库存回收 / 租赁生命周期<br/>（节点退出令牌损失、FLUSHDB 残留）"]
        t5["路径归一化 / 维度基数治理"]
        t6["多规则联合判定（单请求多桶）"]
        t7["Redis 高可用（无 Sentinel/Cluster）<br/>主从切换窗口可重复发放"]
        t8["Redis 返回 EVALSHA 缓存预热 / 连接预热"]
    end

    classDef done fill:#e8f5e9,stroke:#2e7d32;
    classDef planned fill:#fff8e1,stroke:#f9a825,stroke-dasharray: 4 3;
    classDef todo fill:#ffebee,stroke:#c62828,stroke-dasharray: 4 3;
    class d1,d2,d3,d4,d5,d6 done;
    class y1,y2,y3,y4,y5,y6,y7 planned;
    class t1,t2,t3,t4,t5,t6,t7,t8 todo;
```

### 状态明细表

| 状态 | 项 | 说明 |
|---|---|---|
| ✅ | 令牌桶算法 | Redis TIME、ts 单调、burst 封顶、部分授予、wait 计算（`lib/redis.lua` 内嵌脚本） |
| ✅ | 策略指纹 | FNV-1a 32bit → 8 位 hex 进 hash tag；负值归一化；`burst=0≡limit` 等价（`lib/algorithm.lua`） |
| ✅ | batch 两种模式 | batch=1 每请求必经 Redis（日志证实 redis_grant=450）；batch=N 租赁少发上界 |
| ✅ | 本地库存 | shared dict 跨 worker；原子 incr；守恒核算通过；墓碑 TTL 防 key 驻留 |
| ✅ | 故障策略 | 默认 fail-closed(503)；显式 degraded；nil 判定前移无 500；畸形流程无异常栈 |
| ✅ | 验证设施 | quota.sh 每节点断言 + namespace 隔离；xff.sh；指纹 10 断言；守恒探针 |
| 🟡 | 多维限流 | 7 维取值已编码（`dim_value`），仅 ip 维验证过 → `bench/dims.sh`（Phase 2 任务 4.x） |
| 🟡 | Reset/Retry-After/429 日志/防御校验/降级告警/header_name 前置校验 | 全部已设计（change: phase2-dimensions-and-semantics），未实施 |
| ❌ | EVALSHA | 每次全量上传脚本文本（Redis 侧有脚本缓存语义但未利用） |
| ❌ | 可观测性 | 无 Prometheus 指标；RL-DEBUG 为调试态非结构化日志 |
| ❌ | 库存生命周期 | FLUSHDB 后同策略旧库存仍有效（少发方向）；节点退出令牌无回收 |
| ❌ | 基数治理 | path 维度未归一化，`limit_by=[path]` 高基数风险 |
| ❌ | 多规则联合 | 单请求仅一个桶 |
| ❌ | Redis 高可用 | 单实例；主从切换窗口内可能重复发放（design.md §4.6 诚实划界） |

## 4. 已知边界（诚实声明，对应 design.md §4.6/§11）

- Lua 原子 ≠ 主从切换强一致：切换窗口内可能重复发放，上界 ≈ 一个复制周期内的发放量。
- 本地库存是租约不是配额：节点下线/重启即丢失（少发方向）；FLUSHDB 清不掉 worker 库存（必须重启 Kong 才彻底隔离）。
- `batch=1` 时 `X-RateLimit-Remaining` 恒为 0（granted−1 的既有口径，Phase 2 的 remaining 文档化不改变数值）。
