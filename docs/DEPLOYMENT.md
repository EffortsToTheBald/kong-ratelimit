# Deployment and Environment (Docker Compose Verification Environment)

> **Positioning statement**: this document describes the **DB-less / Docker Compose
> verification environment** bundled with this repository. It does not represent verified
> Kubernetes, Redis Cluster, or real production high-availability deployments; for the
> productionization gap see docs/design.md sections 8 and 9 and
> `docs/PHASE6_REQUEST_INTEGRATION_REPORT.md` §14.

## 1. Environment Dependencies

| Dependency | Description |
|---|---|
| Docker Engine + compose v2 | `docker compose version` must be v2 (command is `docker compose`) |
| Host ports | 8030/8031, 8010/8011, 8020/8021, 6380, 5678 must be free |
| OS | Ubuntu 22.04/24.04 verified; other distributions analogous |
| k6 | Required only for the performance matrix (official deb source, see README §5 or docs/bench.md) |

For China-network issues (DNS pollution / mirror acceleration) see `docs/docker-mirror.md`,
or run `./scripts/pull-images.sh` first.

## 2. Compose Service Composition (measured in docker-compose.yml)

| Service | Image | Host port | Description |
|---|---|---|---|
| kong1 | kong:3.6 | proxy 8030 / admin 8031 | `KONG_NGINX_WORKER_PROCESSES=2` |
| kong2 | kong:3.6 | proxy 8010 / admin 8011 | Same as above |
| kong3 | kong:3.6 | proxy 8020 / admin 8021 | Same as above |
| redis | redis:7-alpine | 6380→container 6379 | standalone; `save ""`/no AOF |
| echo | hashicorp/http-echo:1.0 | 5678 | Extremely light upstream, returns `ok` |

- Plugin loading: `KONG_PLUGINS: "bundled,rate-limit-advanced"` + read-only mount of
  `./kong/plugins/rate-limit-advanced` to
  `/usr/local/share/lua/5.1/kong/plugins/rate-limit-advanced`
- Declarative config: read-only mount of `./kong/kong.yml` to `/kong/declarative/kong.yml`
  (initial: limit=1000/window=60/batch=0 (auto→20)/limit_by=ip/namespace=rl/fault_tolerant=false)
- Dependency order: kong waits for redis healthy + echo started

## 3. Starting and Stopping

```bash
docker compose up -d                 # Start all services
docker compose ps                    # Status: 3×kong + redis + echo
docker compose down                  # Stop (keeps volumes)
docker compose down -v               # Stop and clean up volumes
docker compose up -d --force-recreate kong1 kong2 kong3   # Reload plugin code/config (Lua VMs rebuilt with processes)
```

## 4. How the Plugin Is Loaded

1. Code is volume-mounted into the Kong image's plugin directory (see above);
2. The `KONG_PLUGINS` env declares the plugin name;
3. The `kong/kong.yml` declarative config references `rate-limit-advanced`;
4. After modifying plugin code, the Kong containers must be recreated (Lua VMs do not hot-reload).

## 5. Startup Checks

```bash
docker compose ps                                          # Each service Up/healthy
curl -s http://localhost:8031/status                       # kong1 admin plane (200)
curl -s http://localhost:8011/status && curl -s http://localhost:8021/status
docker compose exec -T redis redis-cli ping                # PONG
docker exec kong1 sh -c 'ps aux | grep -c "[n]ginx: worker"'    # = 2
docker compose logs kong1 | grep -i "unknown directive"    # should produce no output
```

## 6. Request Verification

```bash
# Initial config (kong.yml): batch=0 → auto=20 ⇒ first request remaining=19 (measured)
curl -i http://localhost:8030/echo
#   X-RateLimit-Limit: 1000 / X-RateLimit-Remaining: 19 / X-RateLimit-Reset: <Unix seconds>

# Custom config (pushed node by node; DB-less has no global effect)
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

# Multi-replica quota verification (batch=1 strict consistency: 450 requests, exactly 100 200s)
./bench/quota.sh -l 100 -b 1 -p 150
```

## 7. Viewing Redis-Side Data

```bash
docker compose exec -T redis redis-cli --scan --pattern 'kong:rl:*'   # bucket keys / Lease records
docker compose exec -T redis redis-cli HMGET "<bucket key>" tokens ts        # bucket state
docker compose exec -T redis redis-cli INFO commandstats | grep evalsha   # authorization command count
```

- Bucket keys: Hash (tokens/ts), TTL=2×window
- Lease records: `kong:rl:lease:{lease_id}` (lease_id/pool_key/granted/status/created_at), TTL 1h
  (internal constant `LEASE_TTL_MS`, **not automatic inventory return**)

## 8. Viewing Logs

```bash
docker compose logs kong1            # Access logs + plugin logs
docker compose logs -f kong1 kong2 kong3 --tail 100
```

- Failure logs (kept): `limiter unavailable, failing closed/open` (err/warn),
  `429 key=...` (notice), `script cache miss (NOSCRIPT)` (warn), `lease grant failed (...)` (err)
- Hot-path debug logs (`[RL-DEBUG] local_hit/lease_grant/...`) have been at **debug
  level** since Phase 8.2-B: they are emitted only with `KONG_LOG_LEVEL=debug` (compose
  defaults to notice level, so they are not emitted)

## 9. Common Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Proxy ports occupied (8030/8010/8020) | A host process already occupies the ports | Locate the port from the error; change the compose mapping and sync bench/common.sh's PROXY_NODES and k6 NODES |
| `failed to bind host port 6379` | A redis-server already on the host | Mapped to 6380 (6379 inside the container) |
| Containers fail to start, `unknown directive` | Env-injected directive not accepted by this Kong version | Locate the directive from the log; this plugin does not depend on shared dict |
| `POST /config` 400 | JSON body compatibility differences | Use the `-d "config=$(cat kong/kong.yml)"` form form instead |
| Pass count across three nodes > limit | Some nodes did not receive the new config | Check apply_config warnings; manually POST to 8011/8021 |
| `./bench/*.sh: Permission denied` | Execute bit lost when copying from Windows | `chmod +x bench/*.sh` |
| Redis port exhaustion during load testing | Connections not reused | Confirm `set_keepalive` in `lib/redis.lua` is not commented out |
| Plugin code changes not taking effect | Lua VMs do not hot-reload | `docker compose up -d --force-recreate kong1 kong2 kong3` |

## 10. Environment Cleanup

Two independent options:

```bash
# Option one: clear only Redis data (the container must be running)
docker compose exec -T redis redis-cli FLUSHDB
```

```bash
# Option two: full Compose environment reset
docker compose down -v
docker compose up -d
```

> Note: when only Redis is cleared without restarting Kong, Workers may keep consuming
> locally confirmed Lease inventory (frozen semantics; not reclaimed in V1);
> a "full reset" should use option two to rebuild the Kong Workers.

## 11. Boundary Restatement

- This environment is a single-machine Compose verification environment; Redis single
  instance, no persistence
- Not verified: Kubernetes deployment, Redis Cluster/Sentinel, production HA, long-duration stability
- Required reading before production deployment: docs/design.md sections 8 and 9 +
  `docs/PHASE6_REQUEST_INTEGRATION_REPORT.md` §14
