# rate-limit-advanced —— A Kong Distributed Rate-Limiting Plugin

A Kong 3.6 plugin: shares a single global quota pool across N Kong replicas, supports
multi-dimensional rate limiting, atomic multi-rule evaluation, 429 + `Retry-After`, and
dynamic configuration, and slides between "temporal precision / latency / Redis load" via
a single `batch` parameter.

> **What problem it solves**: when multi-replica gateways count independently, the global
> quota gets amplified by the replica count; sending every decision to Redis instead
> introduces one network round trip per request. This plugin puts the **global token bucket
> in Redis (the sole authority)**: with `batch=1` it performs **per-request Redis
> authorization on every request** (strict global consistency); for single-rule `batch>1`,
> each Worker **atomically pre-authorizes a batch of inventory (a Lease, Worker-private)
> from Redis**, and subsequent requests are consumed locally by the Worker first (zero
> network I/O) — trading fewer Redis calls for performance.
>
> **Precision semantics (must be read in full; simplified statements are not accepted)**:
> provided that the Redis authorization state remains continuously valid (no replication
> failover rollback, no data reset) and the accounting basis is consistent, **the cumulative
> number of admitted requests does not exceed the amount of authorization Redis has confirmed
> debiting** (derived). Under-admission error objectively exists in more than one form:
> Worker crash loss, GRANT timeout without retry or registration (single event ≤ batch),
> Pool expiry (EXPIRED, the only state that produces discarded: unconsumed inventory is
> counted into discarded and not returned to Redis; EVICTED is merely an empty-pool
> reclamation event with zero inventory loss); **transient stranding has a derived upper
> bound (≤ total cluster Workers × batch), while cumulative per-window under-admission has
> no closed strict upper bound** (see docs/design.md §4.3 for details). In addition there
> are three classes of risk: ① a policy fingerprint change leaves old and new buckets
> coexisting; during the upgrade window the effective admission cap for the same dimension
> = the sum of both buckets; ② the Redis master-replica async replication rollback window
> can briefly over-admit; ③ local consumption can form short-lived bursts
> (burst_max = B + total Workers × batch, derived upper bound).

**Current implementation scope and limitations**: core implementation, tests, and
performance evidence are complete (Phase 0–7 frozen reports, see the index at the end);
automatic RETURN of inventory, Worker takeover, inventory compensation, and Redis Cluster
are **Deferred, not implemented** (see [Known Limitations](#9-known-limitations)). This is
an engineering-verification-grade project, **not a mature commercial product validated at
large production scale**.

---

## 1. Directory Structure

```
kong-ratelimit/
├── docker-compose.yml            # 3× Kong (DB-less) + Redis 7 + echo upstream
├── docker-compose.mirror.yml     # China-network override (mirror registry)
├── kong/
│   ├── kong.yml                  # Declarative config (initial limit=1000/60s, batch=0 i.e. auto→20)
│   └── plugins/rate-limit-advanced/
│       ├── schema.lua            # Config model + validation (rules and limit_by mutual exclusion, etc.)
│       ├── handler.lua           # access phase: decision / response headers / 429 / 503
│       └── lib/
│           ├── algorithm.lua     # Rate-limit keys + policy fingerprint + three-mode decision (batch=1 / batch>1 / multi-rule)
│           ├── lease.lua         # Worker-private Lease Manager (local TAKE/GRANT, no shared dict)
│           └── redis.lua         # Connection pool + EVALSHA script management (token_bucket / GRANT_LEASE / GRANT_MULTI)
├── redis/                        # Dual-source copy of the Lua scripts (diff-checked against the embedded text in redis.lua)
├── test/                         # Unit tests (resty protocol-level) + E2E (real stack) + Lua protocol matrix
├── k6/                           # quota.js (quota correctness) / latency.js (constant-arrival-rate load test)
├── bench/                        # quota.sh / dims.sh / rules.sh / matrix.sh + common.sh
│   └── raw/phase7/               # Phase 7 performance raw data (95 files)
├── scripts/pull-images.sh        # China mirror-registry pull + retag
└── docs/
    ├── design.md                 # Design document (Current V1 alignment: layered error derivation, D1–D9, Deferred boundaries)
    ├── architecture.md           # Current architecture (three paths / Lease lifecycle / inventory accounting)
    ├── DEPLOYMENT.md             # Deployment and environment (Compose verification environment)
    ├── CONFIGURATION.md          # Configuration fields (schema.lua is authoritative)
    ├── TESTING.md                # Test run index
    ├── bench.md                  # Performance experiment protocol (Phase 7 basis)
    ├── docker-mirror.md          # China-network troubleshooting
    └── reports/                  # Frozen phase reports for Phase 6.3–8.2
```

## 2. Core Features

| Feature | Description | Evidence |
|---|---|---|
| Multi-instance global rate limiting | N replicas share the same Redis quota pool; 3 nodes, 450 requests, exactly 100 admitted | bench/quota.sh |
| Token bucket | rate=limit/window, burst capped, Redis TIME monotonic against clock rewind | redis/token_bucket.lua + dims.sh |
| Multi-dimensional rate limiting | consumer/ip/path/method/header/route/service combinable | bench/dims.sh (8 assertions) |
| batch=1 per-request authorization | One Redis Lua call per request, strict global consistency | Phase 6.4/7: EVALSHA count exactly = request count, Lease records 0 |
| batch>1 Lease pre-authorization | Worker consumes via local TAKE; GRANT_LEASE when inventory is insufficient; **measured authorization commands ≈ 9.99:1 (about 10× reduction)** | Phase 6.5 four-script 66 assertions + Phase 7 accounting |
| Multi-rule atomic authorization | GRANT_MULTI multi-key single script: debit only if all rules are satisfied; if any is insufficient, none are debited | bench/rules.sh (14 assertions, including "one empty + one non-empty ⇒ 429, both buckets unchanged") |
| EVALSHA + NOSCRIPT self-heal | Lazy script loading; only explicit NOSCRIPT triggers LOAD + retry exactly once; timeouts are never treated as NOSCRIPT | test/evalsha-unit.sh + script-cache-selfheal-e2e.sh |
| Fail-close | Redis failure defaults to 503; `fault_tolerant=true` explicitly degrades to fail-open (X-RateLimit-Status: degraded) | test/handler-fault-e2e.sh (26 assertions) |
| 429 + Retry-After | Deterministic rejection strictly distinguished from failure; Retry-After capped at window | rules.sh + dims.sh |
| Multi-Worker local inventory isolation | A Lease belongs only to the Worker that created it; local TAKE is a non-yield atomic snippet | test/lease-unit.sh (50 assertions) + concurrent-lease-e2e.sh (22 assertions) |

## 3. Architecture Overview

```text
Client
  |
  v
Kong replicas ×3 (2 Workers per replica)
  |
  v
rate-limit-advanced (access phase)
  |  Rate-limit key = kong:rl:{<namespace>:p=<policy fingerprint>:<dimension>=<value>...}
  |
  +---- batch=1 (single rule)
  |       |
  |       v
  |     Redis Lua (token_bucket, once per request)
  |
  +---- single rule batch>1
  |       |
  |       v
  |     Worker-local Lease (TAKE)
  |       |
  |       +---- insufficient inventory → Redis GRANT_LEASE (atomic bucket debit + create Lease record)
  |
  +---- multi-rule
          |
          v
       Redis GRANT_MULTI (multi-key atomic, all-or-nothing)
```

- Admitted: 200 + `X-RateLimit-Limit/Remaining/Reset` (**this node's view**)
- Rejected: 429 + `Retry-After` (capped at window)
- Redis failure: 503 (default) / degraded fail-open admission (explicit fault tolerance) — **failures are never disguised as 429**
- For detailed architecture (Lease lifecycle, accounting, script management) see [docs/architecture.md](docs/architecture.md)

## 4. Three Rate-Limiting Modes

| Mode | Authorization | Redis operation | Local inventory | Suitable for |
|---|---|---|---|---|
| `batch=1` | Per-request authorization | Lua executed **per request** | None | Strong consistency, low-QPS critical endpoints |
| Single rule `batch>1` | Lease pre-authorization | Requested when inventory is insufficient (measured about once per 10 requests, batch=10) | Yes (Worker-private) | High QPS when batch-granularity timing and crash-loss exposure are acceptable |
| Multi-rule (`rules`) | Multi-key atomic authorization | GRANT_MULTI executed **per request** | None | Joint quotas (e.g. consumer global + consumer×path) |

Note: `batch>1` is **pre-authorization mode** — quota is debited in batch granularity in
advance, and local consumption can form short-lived bursts (transient burst upper bound
= B + total Workers × batch, derived, docs/design.md §4.5); it does not provide the same
per-request temporal precision as `batch=1`. When a Worker crashes, unconsumed
pre-authorized inventory may be lost (measured sample: granted 10 = consumed 4 + lost 6).
See the Phase 7 report §15 for trade-offs.

**Quantified example (derived basis, do not treat as measured)**: with limit=100, batch=10,
3 nodes × 2 Workers (W_total=6), the derived upper bound of transient stranding = 6 × 10 =
**60 tokens**; 60 / limit(100) = **60% is the inventory exposure ratio (derived upper bound)**
— i.e. the proportion of the quota that could be stranded in the worst case. It is **not
the actual utilization, nor a lower bound of window utilization**: actual stranding is far
smaller than the bound (Workers keep consuming locally, and stranding only approaches the
bound when traffic drops sharply / a Worker crashes / a GRANT is uncertain), and it excludes
cumulative event counts (crashes/uncertain/discarded). For a measured exposure sample of
utilization, see the Phase 7 report (7848 of 255800 grants unconsumed/unconfirmed, 3.1%,
measured aggregate basis).

## 5. Quick Start

Requirements: Ubuntu 22.04/24.04 (or similar), Docker Engine + compose v2; load testing
additionally requires k6.

```bash
cd kong-ratelimit
chmod +x bench/*.sh                # Needed after copying from Windows to restore the execute bit
docker compose up -d               # On China networks see docs/docker-mirror.md first or run ./scripts/pull-images.sh
docker compose ps

curl -s http://localhost:8031/status    # kong1 admin plane health
docker compose exec -T redis redis-cli ping   # Redis connectivity (PONG)

# Fire one shot (kong.yml initial config: limit=1000/60s, batch=0 i.e. auto→20)
curl -i http://localhost:8030/echo
```

Measured first-request response headers (verified in this repository's environment):

```
HTTP/1.1 200 OK
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 19        # GRANT granted=20, this request consumes 1
X-RateLimit-Reset: 1794663881
```

After exhausting the quota (reproducible by switching to a smaller limit config):

```
HTTP/1.1 429 Too Many Requests
Retry-After: <seconds>
```

Multi-replica shared quota verification (150 requests per node, total quota 100 → exactly 100 200s):

```bash
./bench/quota.sh -l 100 -b 1 -p 150    # Expected allowed=100 limited=350 other=0
```

Stop and clean up:

```bash
docker compose down            # Keeps data volumes
docker compose down -v         # Removes volumes as well
```

## 6. Plugin Configuration Example

See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) for the full field table (schema.lua is authoritative).

Single rule + Lease pre-authorization:

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

Multi-rule joint evaluation (mutually exclusive with `limit_by`; `batch` must be 0/1; number of rules ≤ 8):

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

Configuration is pushed node by node via the Admin API (DB-less):

```bash
for port in 8031 8011 8021; do
  curl -X POST "http://localhost:${port}/config" -H 'Content-Type: application/json' -d @config.json
done
```

**Coexistence risk of node-by-node push and how to mitigate it**: DB-less has no shared
configuration plane, so a node that has been pushed to immediately works with the new
policy fingerprint while un-pushed nodes still work with the old fingerprint — the same
logical dimension is accounted separately on **both the old and new sets of buckets, and
the effective admission cap = the sum of the two buckets** (the old bucket dies with the
2×window TTL; new dimension instances receive a fresh initial quota). Mitigation
recommendations: push to all three nodes back-to-back within the same low-traffic window;
after pushing, verify config consistency across nodes via the Admin API; avoid staying in
the "partially updated nodes" state for long (see docs/design.md §6).

## 7. Testing

Category entries and prerequisites are in [docs/TESTING.md](docs/TESTING.md). Quick view:

```bash
bash test/lease-unit.sh                 # Lease Manager protocol-level unit tests (50 assertions)
bash test/algorithm-lease-unit.sh       # Three-mode decision matrix (36 assertions)
bash bench/quota.sh -l 100 -b 1 -p 150  # Multi-replica quota correctness
bash bench/rules.sh                     # Multi-rule all-or-nothing (14 assertions)
bash test/concurrent-lease-e2e.sh       # Multi-Worker concurrency safety (22 assertions)
bash test/worker-crash-e2e.sh           # kill -9 inventory-loss accounting (16 assertions)
```

Unit tests run via resty inside the kong1 container (the script does `docker compose cp`
automatically); the stack must be up first via `docker compose up -d`.

## 8. Performance

Official data: **[docs/reports/PHASE7_PERFORMANCE_REPORT.md](docs/reports/PHASE7_PERFORMANCE_REPORT.md)**
(same-basis k6 constant-arrival-rate, Worker 1/multi × RPS 100/500/1000, raw data in `bench/raw/phase7/`).

Summary (RPS=1000 clean-run means, Worker=2):

| Metric | batch=1 | batch=10 | Multi-rule |
|---|---:|---:|---:|
| p50 / p95 (ms) | 0.66 / 1.41 | 0.50 / 1.16 | 0.68 / 1.44 |
| p99 (ms) | 82.8 | 87.1 | 94.1 |
| Authorization commands (per 20001 requests) | 20001 | 2002 | 20001 |
| Redis total QPS | 4773 | 869 | 7697 |
| Redis CPU (s/20s) | 0.079 | 0.021 | 0.101 |

Conclusion basis (see report §9–§15 for details): authorization commands ≈ 9.99:1 (about
10× reduction), Redis total QPS 4773→869 (**about 81.8% lower**), Kong CPU **about 23%
lower** (0.348→0.269 cores), Redis CPU **about 73% lower** (0.079→0.021s);
p50/p95 reproducibly improved (0.66/1.41 → 0.50/1.16ms);
**p99 showed no improvement, dominated by shared-host environment noise (attribution NOT VERIFIED)**;
the cost is inventory-stranding exposure (7848 of 255800 grants unconsumed/unconfirmed, 3.1%)
and batch-granularity temporal precision. Phase 1 Legacy data (docs/results.md) is for
historical comparison only and does not represent the current implementation.

## 9. Known Limitations

See docs/design.md sections 8 and 9 and the Phase 6.6 integration report §13–§14. Key points:

- **Automatic RETURN / idle scanner / max_lifetime / Worker takeover / inventory compensation: Deferred, not implemented in V1**
- A Worker crash may lose unconsumed Lease inventory (`granted = consumed + lost`; no takeover, no compensation)
- **GRANT timeouts carry result uncertainty** (Redis may have executed while the response was lost): no retry, no local inventory registration, which can cause inventory loss
- Redis Lease metadata has a fixed TTL (1h) — **this is not automatic inventory return**
- Config changes switch to a new Pool via the policy fingerprint; **old Pool lifecycle reclamation is implemented** (Gates 2/3: MAX_POOLS=10000/Worker, max_age=2×window expiry, idle 60s Timer reclamation; unconsumed inventory is counted into discarded and not returned); old inventory drains naturally / dies via TTL
- Redis single instance (compose verification environment); **Cluster / replication failover / K8s / production HA not verified**
- Long-duration stability load testing not completed; `limit_by=path` high-cardinality risk (no path normalization)
- `LEASE_TTL_MS` is an internal constant, not a user-configurable parameter

## 10. Detailed Documentation Index

| Document | Content |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Current architecture: three paths, Lease lifecycle, inventory accounting, EVALSHA management, failure handling |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | Deployment and environment (Compose verification environment setup, checks, troubleshooting, cleanup) |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Full configuration field table (schema.lua basis) |
| [docs/TESTING.md](docs/TESTING.md) | Test run index and prerequisites |
| [docs/bench.md](docs/bench.md) | Performance experiment protocol (Phase 7 basis) |
| [docs/design.md](docs/design.md) | Design document (layered error derivation, production boundaries, Cluster support boundary) |
| [docs/PHASE6_REQUEST_INTEGRATION_REPORT.md](docs/PHASE6_REQUEST_INTEGRATION_REPORT.md) | Phase 6 integration acceptance (final integration report) |
| [docs/reports/PHASE7_PERFORMANCE_REPORT.md](docs/reports/PHASE7_PERFORMANCE_REPORT.md) | Phase 7 official performance report |
| [docs/reports/](docs/reports/) | Frozen phase reports and audits for Phase 6.3–8.2 |

## 11. Differences from the Official Kong rate-limiting Plugin

| | Official OSS plugin | This project |
|---|---|---|
| Algorithm | Fixed-window counting (boundary spikes) | Token bucket (smooth + controllable burst) |
| Distributed | `policy: redis` with one Redis call per request | batch=1 on the same basis; batch>1 Lease pre-authorization (authorization commands measured ≈ 9.99:1, Phase 7) |
| Precision semantics | Errors not stated | Premised precision claim: provided the Redis authorization state is continuously valid, admitted ≤ confirmed debits (derived); under-admission sources listed honestly; over-admission only possible in the failure rollback window (see docs/design.md §4) |
| Multi-dimensional | consumer/ip/header/path/service/route | Same as left + combinations + multi-rule atomic evaluation (all-or-nothing) |
| Failure mode | No explicit degradation statement | Default fail-closed (503); `fault_tolerant=true` explicit degraded fail-open + degraded marker |

See `docs/design.md` section 10 for details.

## 12. Common Failures

| Symptom | Cause | Fix |
|---|---|---|
| `failed to bind host port 0.0.0.0:8000` | Windows `iphlpsvc` occupies 8000 (WSL mirrored networking) | kong1 proxy moved to 8030; if occupied, change docker-compose.yml and sync bench/common.sh's PROXY_NODES and k6 NODES |
| `failed to bind host port 6379` | A local redis-server already on the host | Mapped to 6380; still 6379 inside the container |
| Containers fail to start, logs report `unknown directive` | Kong rejects certain env-injected directives | Check the directive named in the log; this plugin's V1 does not depend on shared dict (inventory is a Worker-private Lua table) |
| `POST /config` returns 400 | Kong version compatibility differences with JSON bodies | Use the `-d "config=$(cat kong/kong.yml)"` form form instead |
| Pass count across three nodes > limit | Only one node received the new config | Check apply_config warning output, or manually POST to 8011/8021 |
| `./bench/*.sh: Permission denied` | Execute bit lost when copying from Windows | `chmod +x bench/*.sh` |
| Redis port exhaustion during load testing | Connections not reused | Confirm `set_keepalive` in `lib/redis.lua` is not commented out |
