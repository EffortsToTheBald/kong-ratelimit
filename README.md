# rate-limit-advanced —— Kong 分布式限流插件

一个 Kong 3.6 插件：在 N 个 Kong 副本之间共享同一个全局配额池，支持多维限流、多规则原子判定、
429 + `Retry-After`、动态配置，并通过一个 `batch` 参数在「时序精度 / 延迟 / Redis 负载」之间滑动。

> **解决什么问题**：多副本网关各自计数时，全局配额会随副本数放大；把每次判定都打到 Redis 又引入
> 每请求一次网络往返。本插件把**全局令牌桶放在 Redis（唯一权威）**，单规则 `batch>1` 模式下每个
> Worker 向 Redis **原子预授权一批库存（Lease）**，之后的请求优先在 Worker 本地消费（零网络 I/O）。
> 库存是从全局桶里原子扣出来的，所以**永远不会超发，只会少发**——误差方向单一，且可给出上界。

**当前实现范围与限制**：核心实现、测试与性能证据完整（Phase 0–7 冻结报告，见文末索引）；
自动 RETURN 归还、Worker 接管、库存补偿、Redis Cluster 属于 **Deferred，尚未实现**（详见
[已知限制](#9-已知限制)）。这是一个工程验证级项目，**不是经过大规模生产验证的成熟商业产品**。

---

## 1. 目录结构

```
kong-ratelimit/
├── docker-compose.yml            # 3× Kong (DB-less) + Redis 7 + echo upstream
├── docker-compose.mirror.yml     # 国内网络 override（镜像站）
├── kong/
│   ├── kong.yml                  # 声明式配置（初始 limit=1000/60s，batch=0 即 auto→20）
│   └── plugins/rate-limit-advanced/
│       ├── schema.lua            # 配置模型 + 校验（rules 与 limit_by 互斥等）
│       ├── handler.lua           # access 阶段：判定 / 响应头 / 429 / 503
│       └── lib/
│           ├── algorithm.lua     # 限流键 + 策略指纹 + 三模式决策（batch=1 / batch>1 / 多规则）
│           ├── lease.lua         # Worker 私有 Lease Manager（本地 TAKE/GRANT，不依赖 shared dict）
│           └── redis.lua         # 连接池 + EVALSHA 脚本管理（token_bucket / GRANT_LEASE / GRANT_MULTI）
├── redis/                        # Lua 脚本双源副本（与 redis.lua 内嵌文本 diff 校验）
├── test/                         # 单测（resty 协议级）+ E2E（真栈）+ Lua 协议矩阵
├── k6/                           # quota.js（配额正确性）/ latency.js（恒定到达率压测）
├── bench/                        # quota.sh / dims.sh / rules.sh / matrix.sh + common.sh
│   └── raw/phase7/               # Phase 7 性能原始数据（95 个文件）
├── scripts/pull-images.sh        # 国内镜像站拉取 + retag
└── docs/
    ├── design.md                 # 冻结设计（误差上界推导、D1–D9 决策）
    ├── architecture.md           # 当前架构（三路径/Lease 生命周期/账目）
    ├── DEPLOYMENT.md             # 部署与环境（Compose 验证环境）
    ├── CONFIGURATION.md          # 配置字段（以 schema.lua 为准）
    ├── TESTING.md                # 测试运行索引
    ├── bench.md                  # 性能实验协议（Phase 7 口径）
    ├── docker-mirror.md          # 国内网络排障
    └── reports/                  # Phase 6.3–8.2 各阶段冻结报告
```

## 2. 核心特性

| 特性 | 说明 | 依据 |
|---|---|---|
| 多实例全局限流 | N 副本共享同一 Redis 配额池；3 节点 450 请求严格放行 100 | bench/quota.sh |
| 令牌桶 | rate=limit/window，burst 封顶，Redis TIME 单调防时钟回拨 | redis/token_bucket.lua + dims.sh |
| 多维限流 | consumer/ip/path/method/header/route/service 可组合 | bench/dims.sh（8 断言） |
| batch=1 逐请求授权 | 每请求一次 Redis Lua，严格全局一致 | Phase 6.4/7：EVALSHA 数恰=请求数、Lease 记录 0 |
| batch>1 Lease 预授权 | Worker 本地 TAKE 消费，库存不足时 GRANT_LEASE；**授权命令实测约 9.99:1（约减少 10 倍）** | Phase 6.5 四脚本 66 断言 + Phase 7 账目 |
| 多规则原子授权 | GRANT_MULTI 多键单脚本：全部满足才扣减，任一不足全部不扣 | bench/rules.sh（14 断言，含"一空一有⇒429 双桶不变"） |
| EVALSHA + NOSCRIPT 自愈 | 脚本懒加载；仅 NOSCRIPT 触发 LOAD+重试恰一次；超时绝不当作 NOSCRIPT | test/evalsha-unit.sh + script-cache-selfheal-e2e.sh |
| Fail-close | Redis 故障默认 503；`fault_tolerant=true` 显式降级放行（X-RateLimit-Status: degraded） | test/handler-fault-e2e.sh（26 断言） |
| 429 + Retry-After | 确定性拒绝与故障严格区分；Retry-After 封顶 window | rules.sh + dims.sh |
| 多 Worker 本地库存隔离 | Lease 只归创建它的 Worker；本地 TAKE 为无 yield 原子片段 | test/lease-unit.sh（25 断言）+ concurrent-lease-e2e.sh |

## 3. 架构概览

```text
Client
  |
  v
Kong 副本 ×3（每副本 2 Worker）
  |
  v
rate-limit-advanced（access 阶段）
  |  限流键 = kong:rl:{<namespace>:p=<策略指纹>:<维度>=<值>...}
  |
  +---- batch=1（单规则）
  |       |
  |       v
  |     Redis Lua（token_bucket，每请求一次）
  |
  +---- 单规则 batch>1
  |       |
  |       v
  |     Worker 本地 Lease（TAKE）
  |       |
  |       +---- 库存不足 → Redis GRANT_LEASE（原子扣桶 + 建 Lease 记录）
  |
  +---- 多规则
          |
          v
       Redis GRANT_MULTI（多键原子，全或无）
```

- 放行：200 + `X-RateLimit-Limit/Remaining/Reset`（**本节点视角**）
- 拒绝：429 + `Retry-After`（封顶 window）
- Redis 故障：503（默认）/ 降级放行（显式容错）——**故障不伪装成 429**
- 详细架构（Lease 生命周期、账目、脚本管理）见 [docs/architecture.md](docs/architecture.md)

## 4. 三种限流模式

| 模式 | 授权方式 | Redis 操作 | 本地库存 | 适用 |
|---|---|---|---|---|
| `batch=1` | 逐请求授权 | **每请求**执行 Lua | 无 | 强一致、低 QPS 关键接口 |
| 单规则 `batch>1` | Lease 预授权 | 库存不足时申请（实测约每 10 个请求 1 次，batch=10） | 有（Worker 私有） | 高 QPS、可接受 batch 粒度时序与崩溃损失敞口 |
| 多规则（`rules`） | 多键原子授权 | **每请求**执行 GRANT_MULTI | 无 | 联合配额（如 consumer 全局 + consumer×path） |

注意：`batch>1` 是**预授权模式**——配额以 batch 粒度预扣，本地消费可能形成短时突发；
它不提供与 `batch=1` 相同的逐请求时序精度。Worker 崩溃时未消费的预授权库存可能损失
（实测样本：granted 10 = consumed 4 + lost 6）。权衡详见 Phase 7 报告 §15。

## 5. 快速启动

环境要求：Ubuntu 22.04/24.04（或同类）、Docker Engine + compose v2；压测另需 k6。

```bash
cd kong-ratelimit
chmod +x bench/*.sh                # 从 Windows 拷贝后需补执行位
docker compose up -d               # 国内网络先看 docs/docker-mirror.md 或跑 ./scripts/pull-images.sh
docker compose ps

curl -s http://localhost:8031/status    # kong1 管理面健康
docker compose exec -T redis redis-cli ping   # Redis 连通性（PONG）

# 打一发（kong.yml 初始配置：limit=1000/60s，batch=0 即 auto→20）
curl -i http://localhost:8030/echo
```

实测首请求响应头（本仓库环境验证）：

```
HTTP/1.1 200 OK
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 19        # GRANT granted=20，本请求消费 1
X-RateLimit-Reset: 1794663881
```

打穿配额后（换一个小 limit 配置即可复现）：

```
HTTP/1.1 429 Too Many Requests
Retry-After: <秒>
```

多副本共享配额验证（3 节点各 150 次，总配额 100 → 恰好 100 个 200）：

```bash
./bench/quota.sh -l 100 -b 1 -p 150    # 期望 allowed=100 limited=350 other=0
```

停止与清理：

```bash
docker compose down            # 保留数据卷
docker compose down -v         # 连同卷一起清理
```

## 6. 插件配置示例

完整字段表见 [docs/CONFIGURATION.md](docs/CONFIGURATION.md)（以 schema.lua 为准）。

单规则 + Lease 预授权：

```json
{
  "name": "rate-limit-advanced",
  "config": {
    "namespace": "api",
    "limit": 100, "window": 3600, "burst": 0,
    "batch": 10,
    "limit_by": ["ip"],
    "fault_tolerant": false,
    "redis": { "host": "redis", "port": 6379, "database": 0, "timeout": 1000 }
  }
}
```

多规则联合判定（与 `limit_by` 互斥；`batch` 只能 0/1；规则数 ≤ 8）：

```json
{
  "name": "rate-limit-advanced",
  "config": {
    "namespace": "api",
    "batch": 0,
    "rules": [
      { "limit": 100, "window": 3600 },
      { "limit": 10,  "window": 3600, "limit_by": ["consumer", "path"] }
    ],
    "redis": { "host": "redis", "port": 6379 }
  }
}
```

配置经 Admin API 逐节点下发（DB-less）：

```bash
for port in 8031 8011 8021; do
  curl -X POST "http://localhost:${port}/config" -H 'Content-Type: application/json' -d @config.json
done
```

## 7. 测试

分类入口与前置条件见 [docs/TESTING.md](docs/TESTING.md)。速览：

```bash
bash test/lease-unit.sh                 # Lease Manager 协议级单测（25 断言）
bash test/algorithm-lease-unit.sh       # 三模式决策矩阵（17 断言）
bash bench/quota.sh -l 100 -b 1 -p 150  # 多副本配额正确性
bash bench/rules.sh                     # 多规则全或无（14 断言）
bash test/concurrent-lease-e2e.sh       # 多 Worker 并发安全（17 断言）
bash test/worker-crash-e2e.sh           # kill -9 库存损失账目（16 断言）
```

单元测试在 kong1 容器内经 resty 执行（脚本自动 `docker compose cp`），需先 `docker compose up -d`。

## 8. 性能

正式数据：**[docs/reports/PHASE7_PERFORMANCE_REPORT.md](docs/reports/PHASE7_PERFORMANCE_REPORT.md)**
（同口径 k6 constant-arrival-rate，Worker 1/多 × RPS 100/500/1000，原始数据 `bench/raw/phase7/`）。

摘要（RPS=1000 干净轮均值，Worker=2）：

| 指标 | batch=1 | batch=10 | 多规则 |
|---|---:|---:|---:|
| p50 / p95 (ms) | 0.66 / 1.41 | 0.50 / 1.16 | 0.68 / 1.44 |
| p99 (ms) | 82.8 | 87.1 | 94.1 |
| 授权命令（每 20001 请求） | 20001 | 2002 | 20001 |
| Redis 总 QPS | 4773 | 869 | 7697 |
| Redis CPU (s/20s) | 0.079 | 0.021 | 0.101 |

结论口径（详见报告 §9–§15）：授权命令约 9.99:1（约减少 10 倍）、总 QPS 5.5×、Redis CPU −73%；
p50/p95 可复现改善；**p99 受共享宿主机环境噪声支配未见改善（归因 NOT VERIFIED）**；
代价为库存留存敞口（255800 授权中 7848 未消费/未确认，3.1%）与 batch 粒度时序精度。
Phase 1 Legacy 数据（docs/results.md）仅作历史对照，不代表当前实现。

## 9. 已知限制

见 [docs/design.md](docs/design.md) 第 8、9 节与 Phase 6.6 集成报告 §13–§14。要点：

- **自动 RETURN / idle scanner / max_lifetime / Worker 接管 / 库存补偿：Deferred，V1 未实现**
- Worker 崩溃可能导致未消费的 Lease 库存损失（`granted = consumed + lost`；不接管、不补偿）
- **GRANT 超时存在结果不确定性**（Redis 可能已执行而响应丢失）：不重试、不登记本地库存，可能造成库存损失
- Redis Lease 元数据有固定 TTL（1h）——**这不等于库存自动归还**
- 配置变化经策略指纹切换新 Pool；**旧 Pool 生命周期回收尚未实现（Deferred）**，旧库存自然耗尽/TTL 消亡
- Redis 单实例（compose 验证环境）；**Cluster / 主从切换 / K8s / 生产 HA 未验证**
- 长时间稳定性压测未完成；`limit_by=path` 高基数风险（无路径归一化）
- `LEASE_TTL_MS` 为内部常量，不是用户可配置参数

## 10. 详细文档索引

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 当前架构：三路径、Lease 生命周期、库存账目、EVALSHA 管理、故障处理 |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | 部署与环境（Compose 验证环境搭建、检查、排障、清理） |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | 配置字段全表（schema.lua 口径） |
| [docs/TESTING.md](docs/TESTING.md) | 测试运行索引与前置条件 |
| [docs/bench.md](docs/bench.md) | 性能实验协议（Phase 7 口径） |
| [docs/design.md](docs/design.md) | 冻结设计（D1–D9、误差上界推导、生产边界） |
| [docs/PHASE6_REQUEST_INTEGRATION_REPORT.md](docs/PHASE6_REQUEST_INTEGRATION_REPORT.md) | Phase 6 集成验收（最终集成报告） |
| [docs/reports/PHASE7_PERFORMANCE_REPORT.md](docs/reports/PHASE7_PERFORMANCE_REPORT.md) | Phase 7 性能正式报告 |
| [docs/reports/](docs/reports/) | Phase 6.3–8.2 各阶段冻结报告与审计 |

## 11. 与 Kong 官方 rate-limiting 插件的差别

| | 官方 OSS 插件 | 本项目 |
|---|---|---|
| 算法 | 固定窗口计数（会边界突刺） | 令牌桶（平滑 + burst 可控） |
| 分布式 | `policy: redis` 每请求一次 Redis | batch=1 同口径；batch>1 Lease 预授权（授权命令实测约 9.99:1，Phase 7） |
| 精度语义 | 未明示误差 | 明确「只少发不超发」+ 上界（batch>1 另有崩溃损失敞口，如实说明） |
| 多维 | consumer/ip/header/path/service/route | 同左 + 组合 + 多规则原子判定（全或无） |
| 故障模式 | 无显式降级声明 | 默认 fail-closed（503）；`fault_tolerant=true` 显式降级 + degraded 标记 |

详见 `docs/design.md` 第 10 节。

## 12. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `failed to bind host port 0.0.0.0:8000` | Windows 的 `iphlpsvc` 占 8000（WSL mirrored 网络） | 已把 kong1 代理改到 8030；若占用改 docker-compose.yml 并同步 bench/common.sh 的 PROXY_NODES 与 k6 NODES |
| `failed to bind host port 6379` | 宿主机已有本地 redis-server | 已映射到 6380，容器内仍是 6379 |
| 容器起不来，日志报 `unknown directive` | Kong 对个别 env 注入指令不接受 | 检查日志报错指令；本插件 V1 不依赖 shared dict（库存为 Worker 私有 Lua table） |
| `POST /config` 返回 400 | Kong 版本对 JSON body 的兼容差异 | 改用 `-d "config=$(cat kong/kong.yml)"` form 形式 |
| 三节点通过数 > limit | 只有一个节点收到新配置 | 检查 apply_config 警告输出，或手动 POST 到 8011/8021 |
| `./bench/*.sh: Permission denied` | 从 Windows 拷贝丢执行位 | `chmod +x bench/*.sh` |
| 压测时 Redis 端口耗尽 | 连接未复用 | 确认 `lib/redis.lua` 的 `set_keepalive` 未被注释 |
