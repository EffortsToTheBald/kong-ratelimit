# PHASE0_REVIEW — Phase 4 Code Current-State Review

> Review baseline: Phase 4 final implementation spec (EVALSHA + Worker-local Lease + idempotent return).
> Review method: file-by-file read-through + in-container measurement (2026-11-12). **This report modifies no production code.**
> HEAD: Phase 0 commits after `e55ff5e` (Phases 1–3 archived, master clean).

## 1. Current Implementation Architecture

```
HTTP Request → Kong access phase (handler.lua, PRIORITY=1002, lower than key-auth 1250)
  → algorithm.build_key(conf)          # bucket key = kong:rl:{<ns>:p=<fingerprint>:<dims>}
  → algorithm.check(conf, key)
        ├─ batch parsing: 0=auto ⇒ clamp(limit/50, 1, 50)
        ├─ batch>1 (fast path): store.take(key) (ngx.shared.DICT atomic decrement)
        ├─ slow path: redis.grant(conf, key, batch, ttl, rate, burst) —— EVAL TOKEN_BUCKET
        │     granted>1 ⇒ store.fill(key, granted−1)
        └─ granted≤0 ⇒ 429 (Retry-After same convention)
Multi-rule (conf.rules non-empty): redis.grant_multi() —— EVAL GRANT_MULTI (all-or-nothing atomic)
Redis failure: fault_tolerant=false ⇒ 503; true ⇒ degraded allowance
```

- Deployment: 3× Kong 3.6 DB-less (fixed 2 workers per node; the compose comment states explicitly "fixed worker count makes shared dict behavior reproducible") + Redis 7 + echo.
- Config push: DB-less per-node POST /config; kong.yml initial limit=1000/window=60/batch=0(auto=20).

## 2. Key Code Files and Functions

| File | Key Content |
|---|---|
| `kong/plugins/rate-limit-advanced/handler.lua` (109 lines) | `init_worker()`: only the shared-dict degradation warning (D5, a Phase 2 artifact); `access()`: build_key → check → response headers/429/503/degradation |
| `.../lib/algorithm.lua` (411 lines) | `build_key()` (fingerprint p=+dims; rules mode group keys g=+r<i>), `policy_fingerprint()` (FNV-1a), `resolve_batch()`, `rate_and_burst()`, `check()` (fast/slow paths), `check_multi()`, `validate_rules()` |
| `.../lib/redis.lua` (411 lines) | `TOKEN_BUCKET` (embedded), `GRANT_MULTI` (embedded), `grant()`/`grant_multi()` (EVAL full-text upload), `parse_grant_response()`/`parse_multi_grant_response()` defensive validation, `connect()` shared connection |
| `.../lib/store.lua` (87 lines) | shared dict `kong_rl`'s `take()` (incr −1, negative rollback + tombstone TTL 60s)/`fill()` (incr +n + expire)/`backend()` |
| `.../schema.lua` | limit/window/burst/batch/limit_by/header_name/namespace/hide_client_headers/fault_tolerant/redis{host,port,password,database,timeout,key_prefix}; entity_checks (header_name precondition, rules mutual exclusion/batch/cap) |
| `redis/token_bucket.lua`, `redis/multi_bucket.lua` | Standalone scripts (Day-1 bare-run/dual-source sync convention: embedded script vs file diff is empty) |
| `kong/kong.yml` | Declarative initial configuration (plugin mounted on the /echo route) |
| `docker-compose.yml` | `KONG_NGINX_HTTP_LUA_SHARED_DICT: "kong_rl 32m"`, `KONG_LOG_LEVEL: notice`, fixed worker count |
| Tests | `bench/quota.sh` (batch=1 exactly 100/batch=20 range), `bench/dims.sh`, `bench/rules.sh`, `bench/matrix.sh`, `bench/xff.sh`, `k6/quota.js`, `k6/latency.js` |

## 3. Current Redis Bucket Fields (measured check)

```
HGET key tokens → floating-point string (e.g., "97.83…")
HGET key ts     → last refill time (Redis TIME seconds)
```

- **Only the fields tokens/ts exist**; rate/capacity are **not in the Bucket**, passed in via ARGV (ARGV[1]=rate, ARGV[2]=burst, ARGV[3]=want, ARGV[4]=ttl_ms).
- New bucket initialization: tokens=burst (full bucket), ts=now.
- refill: `elapsed = max(0, now−ts)` (P0-4 clock-rollback protection implemented); `tokens = min(burst, tokens + elapsed×rate)`.
- Partial grant: `granted = min(want, floor(tokens))`; tokens<1 ⇒ granted=0 (429).
- TTL: `max(1, floor(window×2))×1000` PEXPIRE.

**Comparison with spec §3.1**: tokens ✓, last_refill_time=ts ✓; rate/capacity use the **unified ARGV-passing scheme** (allowed by the spec, and the same pool_key ⇒ same fingerprint ⇒ same rate/capacity is provably consistent). GRANT_LEASE/RETURN_LEASE must reuse the same ARGV scheme (written into tasks 3.1/3.2).

## 4. Current rate/capacity Sources and TTL Policy

- rate = conf.limit / conf.window; capacity = conf.burst>0 ? conf.burst : conf.limit (`rate_and_burst()`).
- TTL = 2×window (bucket state cleanup period, not the refill period).
- **The three scripts (currently two) have consistent refill semantics** (same formula, same shape); the new GRANT_LEASE/RETURN_LEASE must stay isomorphic and pass the same test vectors (tasks 3.5).

## 5. Current EVAL Call Path

- Embedded script text in `redis.lua` + `r:eval(SCRIPT, n, keys..., argv...)` — **full-text upload every time** (the problem Phase 2 solves).
- No SCRIPT LOAD/EVALSHA/SHA cache; no script table.
- Defensive validation (Phase 2 D3 technique): `parse_grant_response`/`parse_multi_grant_response` are pure functions; malformed ⇒ close the connection and enter the fault branch.

## 6. Current Multi-Rule Atomicity Implementation

- `GRANT_MULTI`: KEYS = each rule's bucket key (same hash tag within a group); inside a single script "check all — debit all / debit none", returning the insufficient rules; verified (Phase 3, rules.sh 14 assertions).
- Group key `kong:rl:{<ns>:g=<group fingerprint>:r<i>:<dims>}`; spec §1.1 "multi-rule keeps the original logic" ⇒ **not a single line changed**.

## 7. Gap List vs This Spec

| # | Spec Requirement | Current State | Gap/Action |
|---|---|---|---|
| 1 | EVALSHA + NOSCRIPT self-heal | EVAL full-text upload | Phase 2 implements (script table/LOAD/retry once/timeout ≠ NOSCRIPT) |
| 2 | Unified management of four scripts | Two scripts (TOKEN_BUCKET/GRANT_MULTI) | Add GRANT_LEASE/RETURN_LEASE (Phase 3) |
| 3 | Single-rule batch>1 uses a standalone Lease | store.lua aggregated inventory (shared dict) | **Wholesale replacement** (Phase 4/6); store.lua deleted in Phase 8 |
| 4 | Lease Redis record (OPEN/RETURNED, return_requested) | none | Phase 3 creates lease:{lease_id} |
| 5 | RETURN idempotent commit point (mark first, then bucket) | none | Phase 3 implements (spec §5.2 order, runtime no-rollback argument) |
| 6 | RETURN error code system | none | Phase 3 implements (nine error codes) |
| 7 | Worker-local Lease table/state machine | none (aggregated inventory) | Phase 4 implements |
| 8 | Per-Worker scanner/idle/max_lifetime | none (only the init_worker warning) | Phase 5 implements; the shared-dict warning is removed with Phase 8 |
| 9 | True monotonic clock | **does not exist** — the current state uses no local clock (store has no timestamps); Phase 5 needs one | Phase 0/1.2 verify FFI CLOCK_MONOTONIC; if infeasible ⇒ stop Phase 5 and report |
| 10 | Config snapshot into the Lease | none | Phase 4 lease object carries creation-time idle/max |
| 11 | Metrics convention (lease_*) | only RL-DEBUG logs | Phase 6/7 land with Worker counters + logs (Prometheus deferred) |
| 12 | Performance matrix, three groups | matrix.sh has a batch×RPS skeleton | Phase 1/2/7 extend dimensions (batch 10/50/100, CPU, command classification) |

## 8. Compatibility Impact

1. **batch>1 path rewritten wholesale**: the Phase 1/2 anchor — quota.sh batch=20 range [40,100] (3-node under-grant bound 3×batch) — under the Lease model the under-grant bound is still Σ(per-Worker unclosed remaining) ≈ per-node batch×Worker count; the range semantics are compatible but boundary values may change ⇒ note it in the report; do not change test expectations.
2. **store.lua deletion** (Phase 8): the compose shared-dict injection is decoupled from this plugin; other plugins do not use that dict (kong_rl is a project-specific name) ⇒ deletion is safe, but a full regression run must confirm.
3. **shared-dict degradation warning removal**: handler init_worker's D5 warning loses its target ⇒ removed in Phase 6.
4. **batch=1 and multi-rule paths untouched**: the quota batch=1 baseline/dims/rules serve directly as regression defenses.
5. **New Redis Key lease:{lease_id}**: no conflict with existing bucket keys; the spec requires following the existing key convention ⇒ adopt `kong:rl:lease:{lease_id}` (consistent prefix, standalone has no slot constraint; the Cluster precondition is declared in Design Deferred).

## 9. Implementation Risks

1. **Monotonic clock (highest risk)**: when the environment has no native API, LuaJIT FFI must call `clock_gettime` directly — ABI/compatibility must be measured in Phase 0/1.2; if it fails ⇒ **stop Phase 5** (spec §7.5 allows and requires a report; no silent degradation).
2. **The RETURN idempotent commit point order** is the easiest thing to write backwards this phase ("bucket first, then mark" looks intuitive but would return twice) — tasks 3.2 has a dedicated matrix test pinning it down.
3. **GRANT timeout no-retry** integration with the existing fault branch: timeout ⇒ fault branch (503/degraded); user perception identical to "Redis unavailable"; to be verified in Phase 6.
4. **Lease record count** = GRANT count (bounded by TTL) — Redis memory usage under high traffic must be observed in Phase 7 (report item).
5. **Performance matrix scale** (three groups × multiple dimensions) takes longer — the NOT RUN mechanism backstops, each item labeled as-is.
6. **No blocking items**: no incompatible conflicts found between the spec and the existing code; Phase 1 may begin.

## 10. Files to Modify (summary)

| Phase | Files | Action |
|---|---|---|
| 2 | `lib/redis.lua` | Script table (4 scripts) + EVALSHA wrapper + error-category passthrough |
| 3 | `redis/grant_lease.lua`, `redis/return_lease.lua` (new) + `lib/redis.lua` | Dual-source scripts + call wrappers |
| 4 | `lib/lease.lua` (new) | Worker-level Lease table/TAKE/state machine/closing/GRANT calls |
| 5 | `lib/lease.lua` | Scanner/monotonic clock/retry/config snapshot |
| 6 | `lib/algorithm.lua`, `handler.lua`, `schema.lua` | Wiring/scanner startup/two lifecycle configs/remove the shared-dict warning |
| 7 | `bench/matrix.sh`, `bench/results.md` | Third-group dimensions and report |
| 8 | `lib/store.lua`, `docker-compose.yml`, README/docs | Delete the aggregated implementation and shared dict; documentation sync |

## 11. Phase 1 Concrete Execution Plan

1. Environment self-check (all 5 compose containers running/healthy) + baseline commit (`--allow-empty` anchor).
2. Day-one fact checks: FFI `clock_gettime(CLOCK_MONOTONIC)` (ABI/return value/error handling/measured in container); `CLIENT PAUSE`; empirical proof of Worker-level module table isolation (two workers in independent VMs). **If the FFI check fails ⇒ report and pause Phase 5-related design confirmation (does not block Phase 1/2)**.
3. `matrix.sh` extends the first group's dimensions (batch 1/10/50/100, rates low/mid/high, Workers 1/many, single/multi-rule, Redis CPU, Kong CPU, commandstats classification).
4. Run the EVAL baseline → `bench/results.md` baseline section + raw data saved (bench/out/).
5. Commit `test: add phase4 eval performance baseline`.
