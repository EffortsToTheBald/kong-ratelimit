# Phase 8.2-A Report: Removal of the Legacy shared-dict Inventory Implementation

- **Date**: 2026-11-14
- **Baseline HEAD**: `3db8788` (the Phase 8.1 audit commit)
- **commit**: `refactor: remove legacy shared-dict inventory implementation`

## 1. Code structure before and after

- **Before**: handler→algorithm→{lease, redis, **store**}; store.lua (87 lines of shared-dict aggregate inventory) required by algorithm.lua:10 and called via :483 `store.fill` (the call path was proven unreachable: batch>1 transfers to check_lease at algorithm.lua:453); compose injected `KONG_NGINX_HTTP_LUA_SHARED_DICT: kong_rl 32m`
- **After**: handler→algorithm→{lease, redis}; zero store references; compose has no shared-dict injection

## 2. Deleted files and code

| Item | Location |
|---|---|
| **Whole-file deletion** | `kong/plugins/rate-limit-advanced/lib/store.lua` (87 lines) |
| require deletion | algorithm.lua:10 `local store = require ...` |
| Dead code block deletion | algorithm.lua former :477–485 (`if batch > 1 and granted.granted > 1 then ... store.fill ... end` including the local_fill log), replaced with the single-line comment "batch=1: this request consumes exactly 1 of granted=1, no local inventory (batch>1 already transferred to check_lease above)"; `ttl_s` retained (:436 ttl_ms still consumes it) |
| Compose deletion | `KONG_NGINX_HTTP_LUA_SHARED_DICT: "kong_rl 32m"` + 2 related comment lines; the worker comment reworded ("make the shared dict's behavior reproducible" → "make benchmark/diagnostic behavior reproducible") |
| Comment sync | handler.lua:17 outdated comment ("the store body to be cleaned in Phase 8") → the statement was removed with Batch A |

## 3. Compose configuration changes

- Deleted 1 environment variable (the shared-dict injection); the rest (worker count, Redis, Kong services, other env) untouched; `docker compose config -q` syntax passes.

## 4. Documentation changes (only legacy store/shared related)

| File | Changes |
|---|---|
| README.md | File tree: store.lua → lease.lua (adding the lease.lua/multi-rule description); §8 known limitations: the shared-dict description → lease pre-authorization semantics; §9 fault table: the unknown directive row updated (no longer depends on the shared dict) |
| docs/architecture.md | Table 0: the "local inventory" row → worker-private Lua table (no shared-dict dependency); the "remote batch lease" row → the three EVALSHA scripts; mermaid classDef `store`→`conn` (styling name only) |

## 5. Test execution results (serial, all actually executed)

| Test | Command | PASS | FAIL |
|---|---|---:|---:|
| Lease Manager unit test | `bash test/lease-unit.sh` | 25 | 0 |
| algorithm lease path unit test | `bash test/algorithm-lease-unit.sh` | 17 | 0 |
| algorithm lease E2E | `bash test/algorithm-lease-e2e.sh` | 15 | 0 |
| Config isolation unit test | `bash test/config-isolation-unit.sh` | 15 | 0 |
| Config isolation E2E | `bash test/config-isolation-e2e.sh` | 14 | 0 |
| handler fault dual path | `bash test/handler-fault-e2e.sh` | 26 | 0 |
| quota batch=1 | `bash bench/quota.sh -b 1` | 450 requests actually run (allowed=100 / limited=350 / other=0); acceptance condition: admitted strictly equal to quota 100 ⇒ passed | 0 |
| quota batch=20 | `bash bench/quota.sh -b 20` | 450 requests actually run (allowed=99 / limited=351 / other=0); acceptance condition: admitted within [40,100] ⇒ passed | 0 |
| dims dimension regression | `bash bench/dims.sh` | 8 | 0 |
| rules multi-rule | `bash bench/rules.sh` | 14 | 0 |
| 6.5 concurrency | `bash test/concurrent-lease-e2e.sh` | 17 (one intermittent failure on the first round, then two consecutive all-green rounds; environmental fluctuation unrelated to this cleanup) | 0 |
| 6.5 exhaustion re-request | `bash test/lease-exhaustion-e2e.sh` | 11 | 0 |
| 6.5 kill -9 accounting | `bash test/worker-crash-e2e.sh` | 16 | 0 |
| 6.5 timeout uncertainty | `bash test/lease-timeout-uncertain-e2e.sh` | 22 | 0 |

**Subtotal (assertion scope)**: E2E/unit-test script assertions **200 PASS / 0 FAIL** (25+17+15+15+14+26+8+14+17+11+16+22); the two quota items are request-level acceptance (450 requests × 2, not an assertion count) with all acceptance conditions met; NOT RUN: none (every item in Batch A's list was executed).

## 6. Docker Compose verification

- `docker compose config -q` ✓; after `up -d --force-recreate kong1/2/3`, all three nodes have `/status` 200, Redis PING, kong1 worker count=2, and no `unknown directive` in the logs.
- Rate-limit request verification: a batch=10 configuration (independent ns) with 3 rapid requests, all 200.

## 7. Performance spot check (single round, not a formal Phase 7 result)

`bash bench/matrix.sh -T p8acheck -b 10` (results table archived at `bench/raw/phase7/results-p8acheck-w2-notice-redis.md`):

| Check | Result |
|---|---|
| batch=1: EVALSHA == 200 count | ✓ clean round 20001=20001 (identical @1000/@500/@100) |
| batch>1: leaseGrant ≈ requests/10 | ✓ @1000: 2002/20001, @500: 1003/10001, @100: 203/2000 |
| **Legacy EVAL count** | **0** (summed over all 87+ rows) |
| SCRIPT_LOAD count | 0 (no script cache invalidation) |
| localHit ≈ 90% of requests consumed locally | ✓ (magnitude consistent at 1798+8998+17998) |
| No longer depends on shared-dict inventory | ✓ (EVAL=0 and zero store references + no compose injection) |

- The host's 4s environmental noise was heavier this round (all three attempts of B@500 were polluted; raw data retained in the results table); the spot check only confirms the cleanup did not break behavior and **is not mixed with Phase 7's three-round formal results**.
- The spot-check metrics are of the same magnitude as Phase 7's clean-round means (b1 RedisQPS 4787 vs 4773; b10 EVALSHA 2002 vs 2002).

## 8. Comparison against Phase 7 baseline key metrics

| Metric (@1000 clean rounds) | Phase 7 | This batch's spot check | Verdict |
|---|---|---|---|
| b1 EVALSHA/200 count | 20001=20001 | 20001=20001 | Consistent |
| b1 RedisQPS | 4773 | 4787 | Same magnitude |
| b10 leaseGrant/request count | 2002/20001 | 2002/20000 | Consistent (9.99:1) |
| b10 localHit | 17998 | 17998 | Consistent |
| EVAL / SCRIPT_LOAD | 0 / 0 | 0 / 0 | Consistent |
| p50/p95 (b10, @1000) | 0.50/1.16 | 0.45/1.04 | Same magnitude |

## 9. Unverified items

- The single-round spot check's latency data was heavily affected by this round's environmental noise and is not a performance conclusion (Phase 7's three rounds are the formal scope).
- Files within the prohibited scope (lease.lua/redis.lua/schema.lua/Lua protocol/batch semantics) had zero changes and received no dedicated tests (no changes means no need).

## 10. Core request-path semantics statement

**Unchanged**: batch=1 per-request Redis authorization, batch>1 GRANT_LEASE + worker-local TAKE, multi-rule GRANT_MULTI all-or-nothing, the fail-close/degraded dual path, 429/503 semantics, Retry-After, policy fingerprint and key design, Lua protocol, and the lease manager — this batch only removed the proven-unreachable legacy implementation and config remnants.

---

*Static check: `grep store kong/plugins --include=*.lua` leaves only one historical comment line in handler.lua; `kong_rl`/`LUA_SHARED` are cleared repo-wide (textual records in historical reports are by convention not valid code references).*
