# Phase 6 Request-Path Integration · Final Acceptance Report (V1)

- **Date**: 2026-11-13
- **Baseline**: `a3214b76b70164c51be52458e34fb72f6cc720ed` (final Phase 6.5 commit)
- **Nature**: final integration acceptance — static code audit + test evidence summary + deliverables; zero production code changes

---

## 1. Project Background and Goals of This Refactor

`rate-limit-advanced` is a Kong 3.6 DB-less plugin providing distributed token bucket rate limiting (Redis Lua atomic authorization). Before the refactor (Phase 1–3 Legacy), batch>1 relied on `ngx.shared.DICT` aggregated local inventory, with cross-Worker semantic ambiguity, slow-path Redis pressure, and shared-dict dependency issues.

This refactor (`phase4-performance-and-lease-return` proposal, Phases 4–6): introduces a **Worker Local Lease Manager** — the single-rule batch>1 path becomes "Redis GRANT_LEASE batch pre-authorization + Worker-local TAKE consumption", reducing per-request Redis pressure to O(1/batch), keeping the global quota from over-granting, and adopting an explicit Fail-close failure strategy; confirmed local inventory under batch>1 may continue to be consumed during a Redis outage, while a new GRANT failure enters fault handling.

## 2. V1 Functional Scope and Non-Goals

**Implemented and verified (this report §10–§11)**:
- batch=1: per-request Redis Lua authorization (strictly globally consistent; semantics identical to pre-refactor)
- Single-rule batch>1: GRANT_LEASE batch pre-authorization + Worker-local TAKE
- Multi-rule: GRANT_MULTI atomic multi-key debit (all-or-nothing), not using Leases
- Redis failure Fail-close / fault_tolerant dual paths; timeout-uncertain result handling
- Policy fingerprint configuration isolation; EVALSHA lazy loading + NOSCRIPT self-heal

**V1 non-goals (Deferred, not implemented)**: automatic RETURN, idle scanner, max_lifetime, Worker takeover, inventory compensation, exact real-time lost audit, Redis Cluster, real-time performance metrics. See §13–§14.

## 3. Overall Architecture

```
Request → handler.lua(access)
      ├─ algorithm.build_key(conf) ── bucket key = prefix:{ns:p=<policy fingerprint>:<dim>=value...} (D7 unified format)
      └─ algorithm.check(conf, key)
          ├─ multi-rule          → check_multi → Redis GRANT_MULTI (atomic multi-key, all-or-nothing)
          ├─ batch=1         → Redis token_bucket Lua (EVAL per request, strictly globally consistent)
          └─ single-rule batch>1  → check_lease
              ├─ lease.take(pool_key)      [Worker-local, non-yield atomic section, zero IO]
              ├─ NEED_GRANT → redis GRANT_LEASE (EVALSHA, bucket debit + record creation atomic)
              │     ├─ granted≥1 → lease.grant registration (appended within the same worker VM) → another TAKE consumes exactly 1
              │     ├─ granted=0 → 429 (Retry-After passthrough)
              │     ├─ explicit_error → nil,err (Fail-close; Lua execution errors do not guarantee rollback of prior writes, possibly causing inventory loss, but never registers unconfirmed-authorization inventory locally)
              │     └─ uncertain (timeout/disconnect/malformed) → nil,err (no retry, no registration, loss allowed)
              └─ allow/429 → handler sets X-RateLimit-* headers (remaining = local pool remainder)
```

- Lua VMs are isolated per Worker ⇒ `_pools`/`_counters` are naturally Worker-private (structural isolation, not convention)
- Redis-side responsibilities: global bucket state, GRANT atomic debit and Lease records (TTL 1h); **unaware of local consumption**
- Worker-side responsibilities: inventory consumption (TAKE), Lease lifecycle (ACTIVE→CLOSED one-way), diagnostic counters

## 4. Three Request Paths (code audit conclusion)

| Path | Implementation | Audit Location | Conclusion |
|---|---|---|---|
| batch=1 | per-request `redis_mod.grant` (EVAL token_bucket) | algorithm.lua:452–490 | ✓ zero semantic change from pre-refactor; Phase 6.4 evidenced EVALSHA exactly = request count (450), Lease records=0 |
| Single-rule batch>1 | `check_lease`: local TAKE→GRANT_LEASE→register→another TAKE consumes 1 | algorithm.lua:341–421 | ✓ granted≥1 ⇒ TAKE must succeed; defensive branches treated as faults (never grants unauthorizationed inventory) |
| Multi-rule | `check_multi` → GRANT_MULTI (all-or-nothing) | algorithm.lua:434–436, redis.lua GRANT_MULTI | ✓ does not enter the Lease path; "one empty one non-empty ⇒ 429 with both buckets unchanged" measured |

## 5. Division of Responsibilities: Redis Lua vs Worker Local Lease

- **Redis Lua (Phase 2–3 frozen protocol, dual-source diff checked)**: token_bucket / GRANT_MULTI / GRANT_LEASE / RETURN_LEASE (implemented; not wired in V1). GRANT_LEASE completes atomically in a single script: argument validation→refill→partial grant determination→bucket debit→Lease record creation→TTL; tokens<1 ⇒ granted=0, no record
- **Worker Local Lease (Phase 4, lease.lua)**: `_pools[pool_key]` = `{leases, active}`; TAKE completes check+decrement within a **synchronous section with no yield points** (coroutine scheduling cannot interleave ⇒ complete atomicity proof, no compensation path); invariant `remaining + consumed = granted` (guarded by 25 lease-unit assertions)
- **EVALSHA management (Phase 2)**: lazy loading (init_worker zero IO); only an explicit NOSCRIPT triggers LOAD+retry exactly once; timeout/disconnection is never treated as NOSCRIPT (preventing re-execution after a successful debit)

## 6. Lease Lifecycle and Inventory Ledger

- Lifecycle (V1 frozen): **ACTIVE → CLOSED one-way**. `remaining=0` ⇒ set CLOSED + remove from active (within the same section), retained in the `leases` table for diagnostics only; cannot be revived or re-consumed; no CLOSING return state, no Redis RETURN calls
- Ledger: normal operation `granted = consumed + outstanding`; after a Worker crash `granted = consumed + lost`
- **Measured data (Phase 6.5 worker-crash-e2e, Worker PID=1322, lease `8b8a3f9f9422:1:370:294bea`)**:
  - Before crash: `10 = 4 (consumed) + 6 (outstanding, remaining head sequence 9,8,7,6)`
  - After crash: `10 = 4 + lost 6`; other Workers `90 = 90 + 0`; global `Σgranted=100 = HTTP allowed 94 + lost 6` (94≠100 ⇒ no takeover/compensation/RETURN)
- **Observation convention statement**: consumed is a Worker-local behavior, not directly observable from Redis records; the evidence chain = Redis granted field (record) + HTTP 200 count (exactly 1 TAKE per successful request) + `X-RateLimit-Remaining` header (= local pool remainder, algorithm.lua:423–424), cross-verified across three sources. CLOSED is local semantics; the Redis-side record stays OPEN until TTL 1h

## 7. Policy Fingerprint and Pool Isolation

- Fingerprint inputs (algorithm.lua:35–53): `limit / window / burst (normalized ≤0⇒limit) / limit_by order / header_name (participates only when the header dimension is present)`; **batch excluded** (a transport parameter; changing batch does not clear the bucket)
- `pool_key = build_key output = Redis bucket key` (D7 unified format, not a second key system) ⇒ configuration changes naturally isolate old inventory via fingerprint changes
- Measured: five-dimension isolation matrix + real-stack config change (limit 100→200); the new config's first request remaining=9 (excluding reuse of old inventory 8), new record's fingerprint segment changed (`p=50780f62`→`p=95b99e16`), old record/old bucket unchanged (PHASE6_3_REPORT)

## 8. Redis Failure and Uncertain Result Handling

| Scenario | Semantics | Measured Evidence |
|---|---|---|
| Connection refused | ft=false ⇒ 503 Fail-close; ft=true ⇒ degraded (X-RateLimit-Status: degraded); **never fakes a 429** | handler-fault-e2e 26 assertions |
| Execution timeout | batch=1/batch>1 both enter the existing fault branch; batch>1 uncertain results **no retry, no local inventory registration, never treated as granted=0** | same + scenario B |
| Uncertain result (executed, response lost) | 503; Redis-side record exactly 1 (no retry); a later same-Worker request rem=9 + record +1 (phantom inventory not registered) | lease-timeout-uncertain-e2e scenario B (fd5 keepalive + inode→fd→PID triple ownership check, 22 assertions) |
| Deterministically not executed | 503; records=0 (CLIENT KILL discarding queued commands evidenced) | same, scenario A |
| Existing inventory during a failure | confirmed inventory still locally TAKE-able (all req2-10 200 during PAUSE); after exhaustion, new GRANTs enter the fault branch | P1 scenario |
| After recovery | independent requests grant normally; no duplicate authorization (record increment exactly +1) | fault-recovery-e2e 12 assertions |

## 9. Inventory Loss Semantics After Worker Crash (V1 frozen)

A crashed Worker's outstanding is classified **lost** after the crash: not returned, not compensated, no takeover, no re-authorization. The global ledger is therefore **conservatively loss-biased** (never over-grants). V1 provides no real-time lost metric (Phase 5 Deferred); audit means = GRANT records + consumption counts + crash events + subsequent authorization behavior derivation (§6 measured: 6/100 permanently lost).

## 10. Phase 0–6.5 Implementation Process and Commit Map

| Phase | Content | Key Commits | Delivery Report |
|---|---|---|---|
| Phase 0 | skeleton rollback baseline + P0 review | `0318d2b` | docs/PHASE0_REVIEW.md, review-phase-0.md |
| Phase 1 | correctness baseline (fingerprint keys/monotonic timestamps/Fail-close/load-test convergence/IP dimension regression) | `cb1a2f5`…`f499afe` (groups 1–8), archive `07d392c` | test/phase1-manual.md, docs/results.md |
| Phase 2 | dimensions and semantics (response headers/defensive validation/multi-dimension verification) + archive | `32572d5`…`e156e86`, `cee858c` | docs/PHASE2_REVIEW.md, test/phase2-manual.md |
| Phase 2 (EVALSHA) | script management (lazy loading/NOSCRIPT exactly-once self-heal) | `e4dd6c8`, `b700417`, `3423457` | Phase 2 review (PASS, no P0/P1) |
| Phase 3 (proposal + multi-rule) | rules model/GRANT_MULTI dual source/decision semantics/regression | `e074034`…`f5656bb`, archive `3f78b21` | docs/PHASE3_GROUP1_REPORT.md |
| Phase 3 (Lua protocol) | GRANT_LEASE/RETURN_LEASE scripts + review fixes | `d53f3f0`, `d30592b`, `e1155b5` | lease-redis-matrix.sh 50 assertions |
| Freeze revision | V1 scope adjustment (Phase 5 Deferred, state machine simplification) | `aa3294a`…`089e588` (5 commits) | V1_SCOPE_ADJUSTMENT.md |
| Phase 4 | Worker Local Lease Manager + performance baseline report | `8b04976`, `17cfe37`, `d2a6107` | docs/PHASE4_WORKER_LEASE_REPORT.md |
| Phase 6.1 | algorithm wiring (check_lease/LEASE_TTL_MS) | `a3755aa` | — (evidence embedded in tests) |
| Phase 6.2 | handler cleanup (removes store/shared-dict) + test fixes | `2d4262a`, `55a8131` | — |
| Phase 6.3 | config isolation tests (5 dimensions + real-stack change) + review fixes | `146fdde`, `cbaaf12` | docs/reports/PHASE6_3_REPORT.md |
| Phase 6.4 | full regression + fault dual paths + EVALSHA self-heal + evidence fixes | `f73c0a8`, `63b9d45` | docs/reports/PHASE6_4_REPORT.md |
| Phase 6.5 | concurrency/exhaustion/crash/timeout-uncertain + same-Worker ownership fix | `4622b94`, `a3214b7` | docs/reports/PHASE6_5_REPORT.md |

## 11. Complete Test Matrix

| Phase | Test Content | Execution Status | Result | Evidence Location |
|---|---|---|---|---|
| Phase 0 | code review (P0 baseline) | executed historically | review conclusions on record | docs/PHASE0_REVIEW.md |
| Phase 1 | manual acceptance 11 cases + rule.md A–D + correctness regression | executed historically | all green | test/phase1-manual.md, `f5656bb` |
| Phase 1 | performance baseline (Legacy EVAL + Shared Inventory) | executed historically | see §12 | docs/results.md, bench/raw/phase1/ |
| Phase 2 | manual 10 cases + dims.sh 8 scenarios | executed historically | 8/8 | test/phase2-manual.md, docs/PHASE2_REVIEW.md |
| Phase 2 EVALSHA | evalsha-unit (NOSCRIPT exactly once/timeout not triggering LOAD) | executed historically + 6.4 re-run | 8/8 | test/evalsha-unit.sh |
| Phase 3 | rules.sh 14 scenarios (incl. one empty one non-empty ⇒ 429 with both buckets unchanged) | executed historically + 6.4 re-run | 14/14 | bench/rules.sh |
| Phase 3 Lua | lease-redis-matrix.sh protocol matrix | executed historically | 50 assertions all green | test/lease-redis-matrix.sh, `d30592b`/`e1155b5` |
| Phase 4 | lease-unit 25 / lease-grant-smoke / lease-isolation | executed historically | all green | test/lease-unit.sh, docs/PHASE4_WORKER_LEASE_REPORT.md |
| Phase 6.1 | algorithm-lease-unit 17 + algorithm-lease-e2e 15 | executed historically (6.1 group) | all green | test/algorithm-lease-unit.sh, test/algorithm-lease-e2e.sh |
| Phase 6.2 | handler-fault-e2e 26 (fault dual paths + dual-Worker inventory) | executed historically + indirect regression in 6.4/6.5 | 26/26 | test/handler-fault-e2e.sh |
| Phase 6.3 | config-isolation 15 + real-stack E2E 14 | executed historically (after review fixes) | all green | docs/reports/PHASE6_3_REPORT.md |
| Phase 6.4 | quota b1 (EVALSHA exactly 450/lease 0) + b20 (ledger 355=350+5+95) + dims 8 + rules 14 + handler 26 + fault-recovery 12 + script-cache-selfheal 15 + evalsha-unit 8 | executed historically (63b9d45 v2 convention) | all green (FAIL 0) | docs/reports/PHASE6_4_REPORT.md |
| Phase 6.5 | concurrent 17 + exhaustion 11 + crash 16 + timeout **22** (v2 same-Worker ownership) | **actually executed at final commit a3214b7, 3 consecutive rounds all green** | 66/0/0 | docs/reports/PHASE6_5_REPORT.md |
| Phase 7.2 | same-convention performance measurement of batch=1 vs batch=10 (Lease implementation) | **NOT RUN / Deferred** | — | Spec scenario `same-convention measurement of batch=1 vs batch=10` |
| Phase 5 | automatic RETURN/idle/max_lifetime/takeover | **Deferred (not implemented)** | — | V1_SCOPE_ADJUSTMENT.md |

**Static review evidence (added this phase, Task 1)**: handler.lua (all 106 lines read), algorithm.lua (check/check_lease/fingerprint/build_key), lease.lua (take/grant/classify/CLOSED), redis.lua (evalsha/grant_lease/grant_multi/connect) checked item by item against the frozen Spec/Design — all 11 audits pass (conclusions in §15). Distinct from test evidence: these are code-level checks, not new executions.

## 12. Performance Baseline and Current Performance Evidence Boundary

**Source: docs/results.md (Phase 1 Legacy performance baseline — EVAL + Shared Inventory, k6 v0.54, three rounds of matrix.sh, 20-core shared host; data from real runs)**. Summary (RPS=1000 tier):

| Mode | p99 | Redis QPS | EVAL |
|---|---:|---:|---:|
| M0 baseline (no rate limiting) | 1.8ms | ~0 | 0 |
| batch=1 | 3.1ms | 4865 | 20001 |
| batch=10 | 2.2ms | 434 | 2001 |
| batch=100 | 2.8ms | 42 | 171 |
| Multi-rule | 3.2ms | 7583 | 20001 |

**Boundaries (must be explicit)**:
1. All of the above comes from the **Legacy implementation (EVAL + shared-dict aggregated inventory)** and **cannot represent the current Lease Manager implementation**; it must not masquerade as measured data for the new implementation.
2. Same-convention performance measurement of the current version (Lease path) belongs to Phase 7.2 (Spec scenario `same-convention measurement of batch=1 vs batch=10`), **NOT RUN**.
3. Indirect evidence currently citable (not a performance convention): Phase 6.4 `CONFIG RESETSTAT` + commandstats — under batch=1, EVALSHA exactly = request count (450/450); under batch=20, 450 requests made 355 GRANT attempts and 95 purely local TAKEs with zero Redis. EVALSHA saves script volume bytes versus EVAL (stated factually); **there is no measured evidence of significant latency improvement and no such claim is made**.

## 13. Known Limitations and Deferred Features

**Implemented and verified**: first half of §2 + all behavior in §4–§9 (evidence §11).
**Implemented with limited verification scope**: CLOSED local semantics (invisible to Redis, indirectly evidenced via the remaining sequence); lost audit (derived, no real-time metric); burst=nil≡0 normalization equivalence (unit-covered, part of the design semantics).
**Not implemented (Deferred; must not be claimed)**: automatic RETURN (RETURN_LEASE Lua implemented but not wired in V1), idle scanner, max_lifetime, Worker takeover/inventory compensation, Redis Cluster per-node script caching, monitoring metrics interface, Phase 7 same-convention performance measurement, Phase 8 store.lua cleanup.

## 14. Productionization Gap Analysis (V1 → production grade)

| # | Gap | Impact | V1 Current Handling | Future Direction (not implemented) |
|---|---|---|---|---|
| 1 | Worker crash inventory loss | larger batch ⇒ larger loss (measured 6/100); availability traded for consistency | conservatively loss-biased (no over-grant) + TTL 1h side backstop | Phase 5 RETURN_LEASE wiring + exact lost metrics |
| 2 | batch>1 pre-authorization timing | allowances step in batch granularity; during bursts a single Worker can pre-authorize batch at once | ledger verification convention made explicit (denied-GRANT semantics) | smaller batch/auto strategy documented; tuned by traffic profile |
| 3 | Redis Cluster multi-key Lua | GRANT_MULTI/multi-key scripts require the same slot; single-instance assumption | single-instance deployment (compose standalone) | Clustering requires hash tags or per-ns splitting (Deferred) |
| 4 | Redis HA/failover | during primary failover all GRANTs fail ⇒ Fail-close rejections | existing fault semantics + local inventory buffer (confirmed inventory usable) | Sentinel/Cluster clients, topology-aware retry strategy |
| 5 | Lease TTL vs local lifecycle | Redis record TTL 1h (LEASE_TTL_MS hardcoded), local CLOSED records never cleaned | diagnostic table retained (V1 frozen) | Phase 5: idle/max_lifetime cleanup synchronized on return |
| 6 | Dynamic rate-limit policy updates | old Pool inventory dies out naturally (not returned); local diagnostic table append-only | fingerprint isolation evidenced (new config never reuses old inventory) | pool reclamation strategy (together with Phase 5) |
| 7 | Observability | no Prometheus metrics/tracing; RL-DEBUG notice logs are hot-path noise (P3) | structured error logs + Redis records + remaining header | metrics export (granted/consumed/lost/closed counters already have a _counters basis) |
| 8 | High-concurrency local state | `_pools` grows by (ns, fingerprint, dimension values); memory grows under multi-tenant large dimension cardinality | TTL 1h backstopped by Redis, local diagnostics only | dimension cardinality cap/pool eviction (Deferred) |
| 9 | Long-duration/memory stability | no >24h soak or memory curve | short load tests + unit invariant guarding | soak test suite (Phase 7+) |
| 10 | Performance testing gap | current implementation has no same-convention measured performance (§12) | Legacy baseline + ledger-level Redis command-count evidence | Phase 7.2 same convention (batch=1 vs batch=10, Workers 1/many × three rate tiers) |

**Code-level P2/P3 (no scope expansion this phase; deferred)**:
- P3: algorithm.lua:483 `store.fill` is unreachable dead code inside the batch=1 path (batch>1 now goes through check_lease); the `store.lua` body awaits frozen deletion in Phase 8 (design.md:258, precondition: all tests green)
- P3: the docker-compose `KONG_NGINX_HTTP_LUA_SHARED_DICT: kong_rl 32m` injection is no longer used by the plugin (handler has no shared-dict dependency); the residue is harmless; suggest deleting in Phase 8 with docs synced
- P3: `[RL-DEBUG]` notice-level logs on the hot path (local_hit/lease_grant/lease_take_after_grant); in production should be lowered to debug or made configurable
- P3: `LEASE_TTL_MS=3600000` hardcoded (comment notes it will be handed back to configuration in Phase 5)

**P0/P1: none** (see §15).

## 15. Final Code Audit Conclusions (Task 1, 11 items item by item)

| # | Audit Item | Conclusion | Basis |
|---|---|---|---|
| 1 | Phase 6.1–6.5 implementation matches the frozen Spec/Design | ✓ | file-by-file comparison (location references in §4–§9) |
| 2 | batch=1 keeps the original per-request Redis path | ✓ | algorithm.lua:452; measured EVALSHA=450/450, lease 0 |
| 3 | batch>1 correctly uses the Lease Manager | ✓ | algorithm.lua:453–455 → check_lease |
| 4 | Multi-rule continues GRANT_MULTI, not entering the Lease | ✓ | algorithm.lua:434–436; rules.sh all green |
| 5 | GRANT success registers + the current request consumes exactly 1 | ✓ | algorithm.lua:400–421 (TAKE must succeed + defensive branches treated as faults) |
| 6 | granted=0 correctly 429 + Retry-After | ✓ | algorithm.lua:387–398/465–476; handler D2 cap |
| 7 | Exceptions/uncertain enter fault handling | ✓ | classify four-way classification (explicit_error/uncertain ⇒ nil,err); handler 24–38 |
| 8 | Worker-local inventory strictly isolated | ✓ | lease.lua `_pools` per-VM; structurally invisible; measured full coverage across 6 (host,worker) pairs |
| 9 | Config fingerprint isolates old inventory | ✓ | fingerprint_input (batch excluded); 6.3 all green |
| 10 | Handler has no shared-dict degradation warning/wrong dependencies | ✓ | handler.lua has no store/shared references; VERSION 0.2.0; init_worker V1 notice |
| 11 | Error handling/leaks/state consistency/concurrency safety | ✓ (P3 in §14) | TAKE non-yield atomic; set_keepalive(10s,100); invariant unit guarding; nil checked first (rule.md §9.1 issue A fixed) |

**Issues found**: no P0/P1. All P2/P3 items listed in §14 for future improvement; not delivery-blocking.

## 16. Production Deployment, Monitoring, and Operations Notes

- **Deployment**: the DB-less 3-node × 2-Worker shape is verified; the schema supports single-rule (limit/window/batch/burst/limit_by/header_name) and multi-rule (rules array); `fault_tolerant=false` (default) = Fail-close
- **Tuning**: batch is a trade-off between availability and loss granularity (larger ⇒ less Redis pressure, larger crash loss); the schema allows explicit batch without clamping (large batches require self-assessment of loss exposure); burst≤0 normalized to limit
- **Monitoring suggestions** (based on existing observability points): Redis lease record count/status (SCAN kong:rl:lease:*), bucket tokens (HGET), handler error logs (`limiter unavailable` = fault branch; `lease grant failed (uncertain)` = uncertain result), X-RateLimit-Remaining header sampling
- **Failure drills**: this repo's test scripts can be reused directly for drills (stop redis / CLIENT PAUSE / CLIENT KILL / SIGSTOP·CONT / kill -9 worker)
- **Upgrade notes**: a config change is a fingerprint change ⇒ old inventory dies out naturally (no migration); the Redis script cache is instance-level (the first request after a Redis restart self-heals via NOSCRIPT exactly once)

## 17. Final Acceptance Conclusion

1. **Phase 6.6 complete**: static audit (11 items all pass, no P0/P1) + test evidence summary + performance boundary statement + this report delivered.
2. **Phases 0–6 can be marked complete as a whole**: three request paths, fault semantics, config isolation, concurrency safety, crash loss, and script self-heal all have test evidence; the V1 scope ruling within the frozen range (Phase 5 Deferred) is labeled as-is.
3. **Unresolved P0/P1: none**.
4. **Interview/technical presentation readiness: qualified** — the architecture decision chain (why a Worker-local Lease, why pool_key = bucket key, why uncertain results are not retried), frozen design documents (openspec artifacts + 5 phase reports), the 66 assertions of 6.5 and the full-phase test matrix, and real ledger data (10=4+6 / 100=94+6) can all support a walkthrough; when presenting, one must distinguish "verified behaviors" from "Deferred capabilities" (§13).
5. **Phase 7 starting point**: execute the performance verification per the frozen Spec's `same-convention measurement of batch=1 vs batch=10` scenario (k6 same convention, covering Workers 1/many × rates low/mid/high), producing `test: add phase4 lease performance report`; then execute Phase 8 cleanup per design.md:258 (store.lua/dead code/shared-dict injection/RL-DEBUG log downgrade).

---

*This report is based on the actual code at HEAD `a3214b7` and the real execution records of each phase's reports; production code untouched (git diff contains only this report and the tasks.md status).*
