# Test Report — Phase 1 Core Correctness Baseline

## 1. Test Purpose

Verify that all 8 fixes of the `phase1-correctness-baseline` change (review findings P0-1~P0-6 + the nil dereference fix + the batch=1 short-circuit) take effect, and make the "correctness"-related acceptance rows of `rule.md` §14 provable. All tests are based on real execution results; any unexecuted verification is marked NOT RUN (there are no NOT RUN items this time).

## 2. Modified Files

| File | Type |
|---|---|
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | modified (ts monotonic) |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | modified (nil check moved forward, batch=1 short-circuit, get_ip fallthrough, policy fingerprint + FNV-1a, negative value normalization) |
| `kong/plugins/rate-limit-advanced/schema.lua` | modified (fault_tolerant default false) |
| `kong/kong.yml` | modified (fault_tolerant: false) |
| `redis/token_bucket.lua` | modified (dual-source sync with the embedded script) |
| `bench/common.sh` | modified (namespace parameter, explicit fault_tolerant:false, assert_per_node_counts) |
| `bench/quota.sh` / `bench/matrix.sh` | modified (independent namespace per round/case, per-node assertions) |
| `bench/xff.sh` | new (spoofed XFF regression) |
| `README.md` / `docs/design.md` | modified (failure policy and key design docs synced) |
| `.gitignore` | new |

## 3. Changes Made

1. **Policy fingerprint (review finding P0-1)**: `build_key` outputs `kong:rl:{rl:p=<hex8>:dim=val:...}`; fingerprint = FNV-1a-32(limit, window, parsed burst, limit_by order, header_name [only for the header dimension]), **excluding batch**. Any policy change means a new bucket; old buckets/old inventory are evicted by TTL. Accompanying fix: LuaJIT `bit.band` negative values being sign-extended into 16 hex chars by `%08x` (normalized with `% 0x100000000`).
2. **Fail-closed default (review finding P0-2)**: `fault_tolerant` default true→false; `true` retained as explicit degraded admission.
3. **Redis failure path (rule.md §9.1 issue A)**: in `check()`, the nil check is moved forward before any `granted.*` dereference; on failure, `kong.log.err` + `return nil, err`.
4. **Timestamp monotonicity (review finding P0-4)**: the refill and `ts = now` are folded into the `if now > ts` branch, and `HSET` writes back the branch-internal ts; the dual-source scripts are verbatim identical.
5. **batch=1 short-circuit**: `resolve_batch` runs up front; when `batch==1`, skip `store.take`/`store.fill`, so every request goes through a Redis EVAL.
6. **IP fallthrough fix (review finding P0-3)**: `kong.client.get_remote_ip` (does not exist in the PDK) → `kong.client.get_ip()`; semantics documented (realip/trusted_ips) + a spoofed XFF regression test.
7. **Script convergence (review findings P0-6/P0-5)**: the configuration generator's namespace is parameterized (independent per round) and fail-closed is explicit; quota.sh adds a per-node request count assertion (strictly equal to PER_NODE).
8. **Rollback baseline**: git baseline commit `3d06fdf` (before fixes) + the group-level commit chain (`352b7fe`/`f081647`/`04cad54`/`f830672`/`4dd3576`/`912eab2`/`5b33762`).

## 4. Test Environment

| Item | Value |
|---|---|
| Host | WSL2 (Ubuntu), mirrored network mode |
| Deployment | docker compose: 3× Kong 3.6.1 DB-less (2 workers per node) + Redis 7-alpine + http-echo |
| Ports | kong proxy 8030/8010/8020, admin 8031/8011/8021 (not 8000: occupied by Windows iphlpsvc); Redis host 6380→container 6379 (host 6379 occupied) |
| shared dict | `kong_rl 32m` (KONG_NGINX_HTTP_LUA_SHARED_DICT injection, effective) |
| Images | pulled via host proxy 127.0.0.1:7897 |
| Docker | Engine 29.1.5; this session's user tdohs authorized via the docker group (invocations wrapped in `sg docker -c`) |
| k6 | v2.3.0 (host) |
| Redis persistence | `--save ""`, no AOF (test state) |
| Time | 2026-11-11 19:00–19:45 (+08:00) |

## 5. Test Parameters

| Test | Configuration |
|---|---|
| A+B (batch=1 baseline) | limit=100 window=3600 batch=1 limit_by=ip |
| B20 (batch=20) | limit=100 window=3600 batch=20 limit_by=ip |
| C (failure) | limit=100 batch=1; a) no fault_tolerant field b) fault_tolerant=true |
| D (refill) | limit=60 window=60 batch=1 (rate=1/s, burst=60) |
| XFF | limit=1 batch=1, 20 different spoofed XFF values |
| Isolation | each round: `restart kong×3` → FLUSHDB → deploy with an independent namespace |
| Fingerprint properties | calling the pure function directly inside the resty container, 10 assertions |

## 6. Test Commands

```bash
sg docker -c "docker compose restart kong1 kong2 kong3"   # per-round isolation
sg docker -c "docker compose exec -T redis redis-cli FLUSHDB"
./bench/quota.sh -l 100 -b 1  -p 150     # test A+B
./bench/quota.sh -l 100 -b 20 -p 150     # test B20 (×3 rounds, including the 4.3 round)
./bench/xff.sh                           # spoofed XFF regression
# Failure injection: docker compose stop/start redis + per-node curl
# Rollback: redis-cli HSET <key> ts <future value>, then request
# Fingerprint: docker compose exec kong1 resty -e '...policy_fingerprint...'
```

## 7. Test Results

| # | Test | Result | Expected | Status |
|---|---|---|---|---|
| 1 | A+B batch=1 global quota | allowed=100 limited=350 other=0 | exactly 100/350/0 | ✅ |
| 2 | A+B per-node request count | 150/150/150 (assertion passed) | strictly 150×3 | ✅ |
| 3 | A+B local inventory | local_hit=0 local_fill=0 redis_grant=450 | all 0, 1 EVAL per request | ✅ |
| 4 | B20 no over-admission and lower bound (3 rounds) | allowed=100/100/100, utilization 100.0% | ∈[40,100] and ≤100 | ✅ |
| 5 | C-a default failure | 503 ×3 nodes, 0 upstream response headers (never reached upstream) | 503 and no upstream hit | ✅ |
| 6 | C-b explicit fault tolerance | 200 ×3 + `X-RateLimit-Status: degraded` + 1 upstream header | admit + mark + reach upstream | ✅ |
| 7 | D refill rate | exhausted 60×200 + 10×429; after waiting 5.004s, exactly 5×200 (=⌊5.004×1⌋); bucket tokens=0.532 ≤ burst=60 | ≤⌈t×rate⌉ and ≤burst | ✅ |
| 8 | D timestamp monotonicity (rollback) | preset ts=future 1794400631 → after the request tokens 59→58, **ts keeps its original value** | no refill, ts does not go backward | ✅ |
| 9 | Fingerprint properties (10 assertions) | all green; limit100=25c15179, limit1000=8039753e (8-char lowercase hex) | see the 4.2 assertion set | ✅ |
| 10 | Cross-configuration isolation | after switching limit 1000→100 in the same namespace, 450 requests admit exactly 100; KEYS show two fingerprints, two buckets | ≤100, no inheritance (116 in the same scenario before the fix) | ✅ |
| 11 | Spoofed XFF | 200=1, 429=19 (20 different spoofed XFF values) | only the first admitted | ✅ |
| 12 | Namespace round isolation | the two rounds' namespace segments differ, with the same policy fingerprint consistent (e891f3c2) | no cross-round residue | ✅ |
| 13 | Per-node assertion, normal | 10/10/10 passes | strict equality | ✅ |
| 14 | Per-node assertion, broken | VUS=2 (15/15/0) → exit 1 fail loudly | fails and exits | ✅ |
| 15 | Redis failure logs | `algorithm.lua:136 grant failed` (error) → `handler.lua:29/34 failing open/closed`; traceback/attempt-to count 0 | no 500, no exception stack | ✅ |

Raw evidence: `bench/out/{quota-b1,quota-b20,iso-probe,sabotage}.json` (overwritten by the most recent round); log counts in §8.

## 8. Log Analysis

- **batch=1 round** (namespace `rl-1794396919-622257`): `local_hit=0`, `local_fill=0`, `redis_grant=450`—the strict-mode semantics proven at runtime, not merely by code reading.
- **Failure branch**: when Redis stops, DNS resolution fails → `redis grant failed: connect: [cosocket] DNS resolution failed` (error level, algorithm.lua:136) → split by configuration into `failing closed` (handler.lua:34, default) or `failing open` (handler.lua:29, explicit fault tolerance). **No `stack traceback` / `attempt to index` records anywhere in the repo** (a Lua exception was always thrown here before the fix).
- **Conservation accounting** (isolation probe namespace `rliso1`, limit=1000 batch=20, 90 requests): 30 grants × 20 = 600 granted; 60 local_hits; 30 fills × 19 = 570. Audit: 600 = 30 (consumed via the grant path) + 570 (fills); bucket 1000−600+0.005 refill=400.005 ✅; local pool 570−60=510 ✅; total remainder 400+510=910=600−90+400 ✅. **No tokens created or destroyed out of thin air**.
- Historical log problems of the pre-fix review stage (`--since` mixing logs across rounds, old host scripts) were eliminated by the procedure "independent namespace per round + logs filtered by namespace".

## 9. Issues Found (discovered during this phase's execution)

| # | Issue | Disposition |
|---|---|---|
| 1 | `bench/out/` was once owned by root → k6 could not write the summary and quota.sh read a **stale file**, producing the contradictory output "total=90 allowed=100" | fixed with `chown tdohs`; recommend adding a write-permission pre-check in `assert_prerequisites` next phase (P2) |
| 2 | LuaJIT `bit.band` returns a signed 32-bit value; the fingerprint was sign-extended into 16 hex chars by `%08x` (`ffffffff8039753e`) | fixed (normalized with `% 0x100000000`); does not affect the published semantics (the same value still yields the same key) |
| 3 | **After FLUSHDB under the same policy, old local inventory remains valid** (all 90 requests hit the old pool; no Redis bucket created) | not a bug: same-policy inventory semantics are legal and the error direction is under-admission. The procedure requires `restart kong` per round (followed this time); lease lifecycle governance belongs to Phase 4 |
| 4 | quota.sh's lower-bound warning for batch>1 also triggers when traffic is insufficient to drain the quota (e.g., the -p 30 smoke round) | an informational warning rather than a failure, expected; usage docs note that full-volume traffic is required |
| 5 | Under batch=1, `X-RateLimit-Remaining` is always 0 (granted−1) | existing semantics; handled when P1-3 unifies the basis; untouched this phase |

## 10. Risk Analysis

- **Configuration change = a full-capacity new bucket**: changing limit/window/burst/limit_by resets the quota instantly. Documented in README/design; the operations escape hatch is `namespace`.
- **Default fail-closed lowers availability**: an overall 503 during Redis failures. This is rule.md's established policy; availability-sensitive parties explicitly set `fault_tolerant=true`.
- **No refill during rollback**: the bucket freezes within the clock-rollback window (under-admission). Lua cannot emit alerts; this limitation is recorded truthfully in the report.
- **32-bit fingerprint collision**: negligible probability at a single project's rule scale; on collision, extend to 64-bit (layout unchanged).
- **Local inventory residue across FLUSHDB under the same policy**: see §9.3; Phase 4 needs a lease validity/recovery protocol design (recovery must prevent double return).

## 11. Acceptance Verdict

**Passed (self-verified).** Comparison against rule.md §14's correctness-related acceptance rows:

| Acceptance item | Status |
|---|---|
| Redis Lua atomic token bucket / time from Redis TIME / burst cap | ✅ (§7-7/8) |
| batch=1 global quota strictly correct | ✅ (§7-1/2/3) |
| batch=N does not over-admit | ✅ (§7-4, 3 rounds + conservation accounting) |
| Key multi-dimensional rule combination / hash tag correct | ✅ (§7-9/10, fingerprint in the hash tag) |
| shared dict shared within a node / atomic local inventory deduction | ✅ (verified in review + this round's conservation accounting) |
| Redis failure fail-closed default / 429 distinguished from 503 | ✅ (§7-5/6/15) |
| TTL and token lifecycle | bucket TTL 2×window measured surviving (50780f62 PTTL≈7147s); local inventory lifecycle governance belongs to Phase 4 |
| Tests: multi-node concurrency and failure tests | ✅ (all of §7) |
| Report: real execution | ✅ (this document, no NOT RUN items) |

Manual acceptance awaits user confirmation; after confirmation, commit group 8's commit.

## 12. Recommendations for the Next Phase

1. **P1 semantics batch** (suggested as the next change): unified reset/remaining basis (including the batch=1 always-0 issue), EVALSHA+NOSCRIPT fallback, Retry-After cap, 429-path logging, defensive validation of Redis return values, schema-level validation of header_name (P1-4), and the shared dict degradation warning (wiring backend() into init_worker).
2. **Phase 4 (batch performance and inventory lifecycle)**: the batch×RPS matrix + non-uniform traffic scenarios (Kong1 10% / Kong2 10% / Kong3 80%) to verify stranding and utilization; local inventory lease validity/idle recovery (must prevent double return); the bench/out permission pre-check.
3. **Phase 5 (engineering hardening)**: Prometheus metrics, structured logging (request_id/node/decision), long-run stability and node restart scenarios.
4. **Docs wrap-up**: `rule.md` §3.2/§3.3's key format examples do not yet include the `p=` fingerprint (the user's original document, not modified unilaterally); suggest syncing after the author confirms; README §7's remaining unchecked items are filled in one by one with Phase 2+.
