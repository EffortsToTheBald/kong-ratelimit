# Kong 分布式限流插件（Take-home 考题一）

一个 Kong 3.x 插件：在 N 个网关副本之间共享同一个配额池，支持多维限流、429 + `Retry-After`、动态配置，
并通过一个 `batch` 参数在「精度 / 延迟 / Redis 负载」之间滑动。

> 设计思路一句话：**全局令牌桶放在 Redis，本地放"库存"**。请求优先消耗本地库存（零网络 I/O），
> 库存耗尽时才向 Redis 原子领取一批。库存是从全局桶里扣出来的，所以**永远不会超发，只会少发**——
> 误差方向单一，可以给出上界。

运行环境：**Ubuntu 22.04 / 24.04**（Docker Engine + compose v2），其他发行版同理。

---

## 1. 目录结构

```
kong-ratelimit/
├── docker-compose.yml          # 3× Kong (DB-less) + Redis + echo upstream
├── kong/
│   ├── kong.yml                # 声明式配置（初始 limit=1000/60s，batch=auto）
│   └── plugins/rate-limit-advanced/
│       ├── schema.lua          # 配置模型 + 校验
│       ├── handler.lua         # access 阶段：判定 / 响应头 / 429
│       └── lib/
│           ├── algorithm.lua   # key 构建 + 决策主流程
│           ├── store.lua       # 本地库存（shared dict，降级为 worker 内存）
│           └── redis.lua       # 连接池 + 内嵌 Lua 脚本（令牌桶，用 Redis TIME）
├── k6/
│   ├── quota.js                # 配额正确性：3 节点打超额，数 200 vs 429
│   └── latency.js              # 延迟/吞吐：恒定到达率压测
├── bench/
│   ├── common.sh               # 公共函数（配置下发 / Redis 计量 / k6 调用）
│   ├── quota.sh                # E1/E2：配额正确性
│   └── matrix.sh               # E3/E4：batch×RPS 矩阵 → bench/results.md
├── scripts/
│   └── pull-images.sh          # 国内镜像站拉取 + retag（不改 compose）
├── docker-compose.mirror.yml   # 国内网络 override（把镜像指向镜像站）
└── docs/
    ├── plan.md                 # 4 天实施路线（含 6 个验收 Gate）
    ├── design.md               # 设计文档（就是你要交的那份）
    ├── bench.md                # 实验协议 + 结果模板
    └── docker-mirror.md        # 国内网络：DNS 污染 / 镜像加速 / 排障
```

## 2. 环境准备（Ubuntu）

> **国内网络先看这条**：如果 `docker compose up -d` 报
> `dial tcp [2a03:2880:...]:443: i/o timeout`，那是 **DNS 被污染**（域名解析到了无关的 IPv6），
> 不是普通意义上的"被墙"。完整处理见 `docs/docker-mirror.md`；急着开工就先跑 `./scripts/pull-images.sh`。

```bash
# Docker + compose v2
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 curl python3
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"     # 生效需重新登录（或 newgrp docker）

# 校验：必须是 compose v2（命令是 docker compose，不是 docker-compose）
docker compose version

# k6（官方源）
sudo gpg -k
sudo gpg --no-default-keyring \
  --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 \
  --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install -y k6
k6 version
```

## 3. 5 分钟跑起来

```bash
cd kong-ratelimit
chmod +x bench/*.sh          # 从 Windows 拷过来时必须做这一步
docker compose up -d
docker compose ps
curl -s http://localhost:8031/status      # kong1 管理面

# 打一发
curl -i http://localhost:8030/echo
```

预期响应头里有：

```
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 997
X-RateLimit-Reset: 1762...
```

打穿配额后：

```
HTTP/1.1 429 Too Many Requests
Retry-After: 3
```

## 4. 三个节点共享一个池子（核心验证）

```bash
# 3 个节点各打 150 次，总配额 100 → 总共只能过 100 次
./bench/quota.sh -l 100 -b 1 -p 150
```

也可以手动确认（Bash / zsh）：

```bash
for port in 8030 8010 8020; do
  for i in $(seq 1 150); do
    curl -s -o /dev/null -w '%{http_code}\n' "http://localhost:${port}/echo"
  done
done | sort | uniq -c
# 期望：100 个 200，350 个 429
```

> 想看"单机各自为政"的效果：把 `batch` 设成 `1000`（等于把整个配额一次性领到本地），
> 或者把 `redis.database` 改成不同库，各节点就会各自计数。

## 5. 参数：`batch` 是唯一的旋钮

| batch | 语义 | Redis 调用 | 最多少发 | 典型 p99 增量 |
|---|---|---|---|---|
| `1` | 严格全局一致（每请求 1 RTT） | 1 次/请求 | 0 | 由 Redis RTT 主导（~0.3–1ms） |
| `5` | 每 5 个请求领一次 | 1/5 请求 | N×5 | 接近于 0 |
| `20` | 每 20 个请求领一次 | 1/20 请求 | N×20 | ≈0（fast path 无 I/O） |
| `0` | `auto`：`clamp(limit/50, 1, 50)` | 1/⌊limit/50⌋ | ≤ N×(limit/50) ≈ 6% | ≈0 |

其中 N = 副本数。误差上界推导见 `docs/design.md` 第 4 节。

## 6. 跑性能矩阵

```bash
./bench/matrix.sh                       # 默认 batch 0,1,5,20 × RPS 200,1000
./bench/matrix.sh -r 200,1000,3000 -d 60
# 产物：bench/results.md（markdown 表格，直接贴进设计文档）
```

脚本会：逐组 `POST /config` 到三个节点 → 采样 Redis 命令数 → 跑 k6 → 输出 markdown。
原始 summary 在 `bench/out/`。

## 7. 验收清单（做完打勾）

- [ ] 单节点：`limit=5/window=60`，第 6 个请求返回 429，`Retry-After` 合理
- [ ] 三节点：`limit=100/window=3600`，总通过数 **恰好 100**（`batch=1`）
- [ ] 三节点：同上但 `batch=20`，总通过数落在 **[40, 100]**（少发，不超发）
- [ ] 多维：`limit_by: [ip, path]`，不同 path 独立计数
- [ ] 动态配置：`POST /config` 改 limit，10s 内生效且不重启
- [ ] Redis 挂掉：`docker compose stop redis` → 请求仍放行并带 `X-RateLimit-Status: degraded`
- [ ] 性能：`batch=20` 的 p99 与无插件基线差 < 1ms

## 8. 已知限制 / 生产化差距

见 `docs/design.md` 第 8、9 节。要点：Redis 主从切换窗口内可能重复发放；单 key 热点；
`limit_by=path` 的高基数风险；shared dict 需要改 `kong.conf`（本项目用 `KONG_NGINX_HTTP_LUA_SHARED_DICT`）；
默认 fail-open 是可用的取舍，但金融场景要改成 fail-closed。

## 9. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| `failed to bind host port 0.0.0.0:8000` | Windows 的 `iphlpsvc` 占 8000，且 WSL 是 mirrored 网络模式 | 已把 kong1 改到 8030；若 8030 也被占，改 `docker-compose.yml` 并同步改 `bench/common.sh` 与 k6 里的 NODES |
| `failed to bind host port 6379` | 宿主机已有本地 redis-server | 已映射到 6380，容器内仍是 6379 |
| 容器起不来，日志报 `unknown directive` | `KONG_NGINX_HTTP_LUA_SHARED_DICT` 没被接受 | 临时删掉该环境变量，插件会降级为 worker 内存表（精度下降但能跑） |
| `POST /config` 返回 400 | Kong 版本对 JSON body 的兼容差异 | 改用 `-d "config=$(cat kong/kong.yml)"` 提交 form 形式 |
| 三个节点通过数加起来 > limit | 只有一个节点收到了新配置 | 检查 `apply_config` 的警告输出，或手动 `curl -X POST` 到 8011/8021 |
| 压测时 Redis 端口耗尽 | 忘了 keepalive | 确认 `lib/redis.lua` 里的 `set_keepalive` 没被注释 |
| `./bench/*.sh: Permission denied` | 从 Windows 拷贝丢了执行位 | `chmod +x bench/*.sh` |

## 10. 和 Kong 官方 rate-limiting 插件的差别

| | 官方 OSS 插件 | 本项目 |
|---|---|---|
| 算法 | 固定窗口计数（会边界突刺） | 令牌桶（平滑 + 可控突发） |
| 分布式 | `policy: redis` 每请求一次 Redis | 本地库存 + 批量领取，Redis 负载 ÷batch |
| 精度语义 | 未明示误差 | 明确给出「只少发不超发」的上界 |
| 多维 | consumer/ip/header/path/service/route | 同左 + 组合 |
| 故障模式 | 无显式降级声明 | `fault_tolerant` + `X-RateLimit-Status: degraded` |

详见 `docs/design.md` 第 10 节。
