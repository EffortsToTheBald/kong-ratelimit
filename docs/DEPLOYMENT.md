# 部署与环境（Docker Compose 验证环境）

> **定位声明**：本文档描述的是本仓库自带的 **DB-less / Docker Compose 验证环境**。
> 它不代表已验证 Kubernetes、Redis Cluster 或真实生产高可用部署；生产化差距见
> `docs/design.md` 第 8、9 节与 `docs/PHASE6_REQUEST_INTEGRATION_REPORT.md` §14。

## 1. 环境依赖

| 依赖 | 说明 |
|---|---|
| Docker Engine + compose v2 | `docker compose version` 必须是 v2（命令为 `docker compose`） |
| 宿主端口 | 8030/8031、8010/8011、8020/8021、6380、5678 需空闲 |
| OS | Ubuntu 22.04/24.04 实测通过；其他发行版同理 |
| k6 | 仅性能矩阵需要（官方 deb 源，见 README §5 或 docs/bench.md） |

国内网络问题（DNS 污染/镜像加速）见 `docs/docker-mirror.md`，或先跑 `./scripts/pull-images.sh`。

## 2. Compose 服务组成（docker-compose.yml 实测）

| 服务 | 镜像 | 宿主端口 | 说明 |
|---|---|---|---|
| kong1 | kong:3.6 | 代理 8030 / 管理 8031 | `KONG_NGINX_WORKER_PROCESSES=2` |
| kong2 | kong:3.6 | 代理 8010 / 管理 8011 | 同上 |
| kong3 | kong:3.6 | 代理 8020 / 管理 8021 | 同上 |
| redis | redis:7-alpine | 6380→容器 6379 | standalone；`save ""`/无 AOF |
| echo | hashicorp/http-echo:1.0 | 5678 | 极轻上游，返回 `ok` |

- 插件加载：`KONG_PLUGINS: "bundled,rate-limit-advanced"` + 把 `./kong/plugins/rate-limit-advanced`
  只读挂载到 `/usr/local/share/lua/5.1/kong/plugins/rate-limit-advanced`
- 声明式配置：`./kong/kong.yml` 只读挂载到 `/kong/declarative/kong.yml`
  （初始：limit=1000/window=60/batch=0（auto→20）/limit_by=ip/namespace=rl/fault_tolerant=false）
- 依赖顺序：kong 等待 redis healthy + echo started

## 3. 启动与停止

```bash
docker compose up -d                 # 启动全部服务
docker compose ps                    # 状态：3×kong + redis + echo
docker compose down                  # 停止（保留卷）
docker compose down -v               # 停止并清理卷
docker compose up -d --force-recreate kong1 kong2 kong3   # 重载插件代码/配置（Lua VM 随进程重建）
```

## 4. 插件加载方式

1. 代码经 volume 挂载进 Kong 镜像的插件目录（见上）；
2. `KONG_PLUGINS` env 声明插件名；
3. `kong/kong.yml` 声明式配置内引用 `rate-limit-advanced`；
4. 修改插件代码后必须 recreate Kong 容器（Lua VM 不热加载）。

## 5. 启动检查

```bash
docker compose ps                                          # 各服务 Up/healthy
curl -s http://localhost:8031/status                       # kong1 管理面（200）
curl -s http://localhost:8011/status && curl -s http://localhost:8021/status
docker compose exec -T redis redis-cli ping                # PONG
docker exec kong1 sh -c 'ps aux | grep -c "[n]ginx: worker"'    # = 2
docker compose logs kong1 | grep -i "unknown directive"    # 应无输出
```

## 6. 请求验证

```bash
# 初始配置（kong.yml）：batch=0 → auto=20 ⇒ 首请求 remaining=19（实测）
curl -i http://localhost:8030/echo
#   X-RateLimit-Limit: 1000 / X-RateLimit-Remaining: 19 / X-RateLimit-Reset: <Unix 秒>

# 自定义配置（逐节点下发，DB-less 无全局生效）
cat > /tmp/cfg.json <<'EOF'
{"_format_version":"3.0","services":[{"name":"echo","url":"http://echo:5678",
 "routes":[{"name":"echo-route","paths":["/echo"],"strip_path":false,
 "plugins":[{"name":"rate-limit-advanced","config":{"namespace":"demo",
   "limit":100,"window":3600,"batch":10,"burst":0,"limit_by":["ip"],
   "fault_tolerant":false,
   "redis":{"host":"redis","port":6379,"database":0,"timeout":1000}}}]}]}]}
EOF
for port in 8031 8011 8021; do
  curl -X POST "http://localhost:${port}/config" -H 'Content-Type: application/json' -d @/tmp/cfg.json
done

# 多副本配额验证（batch=1 严格一致：450 请求恰 100 个 200）
./bench/quota.sh -l 100 -b 1 -p 150
```

## 7. Redis 侧数据查看

```bash
docker compose exec -T redis redis-cli --scan --pattern 'kong:rl:*'   # 桶键/Lease 记录
docker compose exec -T redis redis-cli HMGET "<桶键>" tokens ts        # 桶状态
docker compose exec -T redis redis-cli INFO commandstats | grep evalsha   # 授权命令计数
```

- 桶键：Hash（tokens/ts），TTL=2×window
- Lease 记录：`kong:rl:lease:{lease_id}`（lease_id/pool_key/granted/status/created_at），TTL 1h
  （内部常量 `LEASE_TTL_MS`，**不是库存自动归还**）

## 8. 日志查看

```bash
docker compose logs kong1            # 访问日志 + 插件日志
docker compose logs -f kong1 kong2 kong3 --tail 100
```

- 故障日志（保留）：`limiter unavailable, failing closed/open`（err/warn）、
  `429 key=...`（notice）、`script cache miss (NOSCRIPT)`（warn）、`lease grant failed (...)`（err）
- 热路径调试日志（`[RL-DEBUG] local_hit/lease_grant/...`）自 Phase 8.2-B 起为 **debug 级**：
  需 `KONG_LOG_LEVEL=debug` 才输出（compose 默认 notice 级不输出）

## 9. 常见故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 代理端口被占用（8030/8010/8020） | 宿主机已有进程占用对应端口 | 按报错定位端口；更换 compose 映射并同步 bench/common.sh 的 PROXY_NODES 与 k6 NODES |
| `failed to bind host port 6379` | 宿主机已有 redis-server | 已映射 6380（容器内 6379） |
| 容器起不来，`unknown directive` | env 注入指令不被该 Kong 版本接受 | 按日志定位指令；本插件不依赖 shared dict |
| `POST /config` 400 | JSON body 兼容差异 | 改 `-d "config=$(cat kong/kong.yml)"` form 形式 |
| 三节点通过数 > limit | 部分节点未收到新配置 | 检查 apply_config 警告；手动 POST 8011/8021 |
| `./bench/*.sh: Permission denied` | Windows 拷贝丢执行位 | `chmod +x bench/*.sh` |
| 压测 Redis 端口耗尽 | 连接未复用 | 确认 `lib/redis.lua` 的 `set_keepalive` 未被注释 |
| 改了插件代码没生效 | Lua VM 不热加载 | `docker compose up -d --force-recreate kong1 kong2 kong3` |

## 10. 环境清理

两个独立方案：

```bash
# 方案一：仅清空 Redis 数据（容器必须处于运行状态）
docker compose exec -T redis redis-cli FLUSHDB
```

```bash
# 方案二：完整重置 Compose 环境
docker compose down -v
docker compose up -d
```

> 注意：只清 Redis 不重启 Kong 时，Worker 本地已确认的 Lease 库存仍可能继续消费（冻结语义，V1 不回收）；
> 需要"完全重置"时应采用方案二重建 Kong Worker。

## 11. 边界重申

- 本环境为单机 Compose 验证环境；Redis 单实例，无持久化
- 未验证：Kubernetes 部署、Redis Cluster/Sentinel、生产 HA、长稳
- 生产部署前必读：`docs/design.md` 第 8、9 节 + `docs/PHASE6_REQUEST_INTEGRATION_REPORT.md` §14
