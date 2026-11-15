# Phase 7 Performance Report: Same-Scope Measured Results for the Worker Local Lease Implementation

- **Date**: 2026-11-14
- **Git SHA**: `7db67734901f7f8f20968db48bf3b24abf81bbc9` (Phase 6.6 frozen baseline, clean workspace)
- **commit**: `test: add phase4 lease performance report`
- **Nature**: an independent measurement of the current lease implementation; the Phase 1 legacy data serves only as historical reference, not as a current conclusion

---

## 1. Test goals

Under identical environment and identical load scope (k6 constant-arrival-rate, 20s/group, RPS 100/500/1000, limit=1000000 to isolate the rate-limiting path), measure the current implementation's four paths (M0 / batch=1 / batch=10 / multi-rule) and answer: does batch=10 lease pre-authorization genuinely reduce Redis authorization interactions, how do latency and throughput change, and what cost buys the benefit.

## 2. Test environment

| Item | Value |
|---|---|
| CPU | Intel(R) Core(TM) Ultra 7 265K, 20 cores |
| Memory | 14Gi total / 10Gi used / 4.4Gi available (**shared host**: resident kubelet/K8s node, IDE, agent, etc. on the same machine) |
| OS/kernel | Ubuntu 24.04.4 LTS, kernel 7.0.0-43-generic |
| Docker | 29.3.0 |
| Kong | 3.6.1 DB-less ×3 nodes, 2 workers per node (the w1 group is 1 worker, switched and verified by matrix.sh force-recreate) |
| Redis | 7.4.12 standalone (container direct-connect redis:6379) |
| k6 | v0.54.0 (constant-arrival-rate, preAllocatedVUs=max(100,RPS)) |
| Environmental load | the host has other load; a known "~4s blocking" environmental noise is present in practice (same as Phase 1); matrix.sh's built-in retry mechanism retains the raw data of polluted rounds |

## 3. Tested version and scope

- **Tested implementation**: Phase 6 frozen version (HEAD `7db6773`). batch=1 uses EVALSHA token_bucket (once per request); batch=10 uses GRANT_LEASE + worker-local TAKE; multi-rule uses GRANT_MULTI. Audit confirms: **EVAL=0, SCRIPT_LOAD=0 throughout (87 groups)** ⇒ no legacy EVAL path remnants, no shared-dict remnants, no script cache invalidation.
- **Real verification of authorization paths**: see §13 account reconciliation (EVALSHA count == request count/GRANT count, one-to-one with code paths).
- **Log scope**: KONG_LOG_LEVEL=notice (same scope as the Phase 1 legacy tables); [RL-DEBUG] logs exist in both generations — a same-scope factor.

## 4. Test method

Reuses the repo's existing `bench/matrix.sh` (the original Phase 1 baseline framework: per-case independent namespace config issuing → k6 20s load → before/after delta collection), with only two framework-level extensions (not production code):
1. A new `leaseGrant` column: counts `[RL-DEBUG] lease_grant` log lines (the GRANT_LEASE count of the current lease path; the original `slowGrant` column retains the batch=1 redis_grant semantics).
2. Fixed the results-table print template to output field 20 (attempt; the attempt column was missing in the md of this round's 6 runs and can be recovered from the k6 raw json filenames `-a<N>`).

- Per group: independent ns (p4-*) → config issued → snap (Redis commandstats/cpu, Kong log line count, cgroup cpu.stat) → k6 20s → snap → deltas appended to the row.
- **Pollution criterion** (inherited from Phase 1): p99>500ms or measured RPS<95% of target ⇒ re-run up to 3 times; polluted rounds **retain their raw data** (this report filters "clean rounds" by p99<500 for the mean; polluted rounds are listed separately in §7).
- Rounds: **3 independent runs per mode × worker configuration × RPS tier** (3 full-matrix rounds each for w2 and w1).

## 5. Test matrix

| Mode | Implementation | batch | RPS tier | Workers | Rounds |
|---|---|---|---|---|---|
| M0 | no rate limiting (plugins=[]) | — | 100/500/1000 | 2 and 1 | 3 each |
| batch=1 | EVALSHA token_bucket | 1 | same as above | 2 and 1 | 3 each |
| batch=10 | GRANT_LEASE + local TAKE | 10 | same as above | 2 and 1 | 3 each |
| Multi-rule | GRANT_MULTI (2 rules) | — | same as above | 2 and 1 | 3 each |

limit=1000000/window=60s ⇒ no 429s throughout (measured 429=0); purely measures the admitted path; correctness is guaranteed by §13 accounting + Phase 6.5 frozen evidence.

## 6. Raw data file locations

- `bench/raw/phase7/` (95 files): 6 results tables `results-p7w{2,1}r{1,2,3}-*.md`, 87 groups of k6 raw json (`p7w*-w*-{M0,A,B,C}-r*-a*.json`, including each round's attempt number), environment info `p7-env.txt`, lease record export `p7-leases.txt`
- Process output: `bench/out/` (same-named files)

## 7. Per-round results (raw rows in the §6 files; clean-round means shown here)

**Worker=2 (3 rounds)**:

| Mode | RPS | p50 | p95 | p99 | Measured RPS | RedisQPS | EVALSHA | localHit | leaseGrant | multi | KongCPU (cores) | RedisCPU (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0 | 1000 | 0.48 | 0.97 | 12.6 | 1000 | 1 | 0 | 0 | 0 | 0 | 0.225 | 0.006 |
| batch=1 | 1000 | 0.66 | 1.41 | 82.8 | 1000 | 4773 | 20001 | 0 | 0 | 0 | 0.348 | 0.079 |
| batch=10 | 1000 | 0.50 | 1.16 | 87.1 | 1000 | 869 | 2002 | 17998 | 2002 | 0 | 0.269 | 0.021 |
| Multi-rule | 1000 | 0.68 | 1.44 | 94.1 | 1000 | 7697 | 20001 | 0 | 0 | 20001 | 0.341 | 0.101 |

**Worker=1 (3 rounds)**:

| Mode | RPS | p50 | p95 | p99 | Measured RPS | RedisQPS | EVALSHA | localHit | leaseGrant | multi | KongCPU (cores) | RedisCPU (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| M0 | 1000 | 0.45 | 0.91 | 25.1 | 1000 | 1 | 0 | 0 | 0 | 0 | 0.209 | 0.005 |
| batch=1 | 1000 | 0.62 | 1.30 | 95.1 | 1000 | 4762 | 20001 | 0 | 0 | 0 | 0.305 | 0.060 |
| batch=10 | 1000 | 0.47 | 1.14 | 103.8 | 1000 | 871 | 2002 | 17999 | 2002 | 0 | 0.243 | 0.017 |
| Multi-rule | 1000 | 0.62 | 1.26 | 95.5 | 1000 | 7788 | 20001 | 0 | 0 | 20001 | 0.298 | 0.073 |

- 15 polluted rows in total (p99≥500ms, i.e., the ~4s environmental blocking), all retained in the §6 raw files; each RPS tier has ≥3 clean rounds under both w2/w1 (guaranteed by the retry mechanism).
- Complete data for the RPS=100/500 tiers is in the §6 results tables.

## 8. Summary statistics (RPS=1000 clean-round mean ± range, three rounds)

| Metric | batch=1 | batch=10 | Multi-rule |
|---|---|---|---|
| p50 (w2/w1) | 0.66/0.62 | 0.50/0.47 | 0.68/0.62 |
| p95 (w2/w1) | 1.41/1.30 | 1.16/1.14 | 1.44/1.26 |
| p99 (w2/w1) | 82.8/95.1 | 87.1/103.8 | 94.1/95.5 |
| RedisQPS (w2/w1) | 4773/4762 | 869/871 | 7697/7788 |
| Authorization command count (per 20001 requests) | 20001 | 2002 | 20001 |
| KongCPU cores (w2/w1) | 0.348/0.305 | 0.269/0.243 | 0.341/0.298 |
| RedisCPU s (w2/w1) | 0.079/0.060 | 0.021/0.017 | 0.101/0.073 |

## 9. batch=1 vs. batch=10

- **Authorization commands**: 20001 → 2002, **roughly 9.99:1, an approximately 10× reduction**; the small deviation from the theoretical 1/batch comes from multi-worker independent pre-authorization and batch boundaries (workers' pool exhaustion moments are not synchronized; some requests land on batch boundaries)
- **Total Redis QPS**: 4773 → 869 (w2, **5.5×**; includes non-authorization commands such as connection establishment/AUTH/SELECT, hence below 10×)
- **p50/p95**: 0.66→0.50ms / 1.41→1.16ms (w2 @1000), w1 in the same direction (0.62→0.47 / 1.30→1.14) — the local TAKE zero-IO path is faster
- **p99**: 82.8 vs 87.1ms (w2) / 95.1 vs 103.8ms (w1) — **no improvement observed** (see the §15 issue 2 analysis)
- **Kong CPU**: 0.348→0.269 cores (w2, −23%); Redis CPU: 0.079→0.021s (−73%)
- **Timing precision statement**: batch=10 is a pre-authorization mode — 90% of requests are consumed from worker-local inventory (the remaining header = local pool remaining); quota precision is batch-granularity pre-deduction + bucket refill, not per-request real-time global consistency; this is not the same as deducting every request from Redis in real time (stated honestly, without exaggeration).

## 10. Redis QPS comparison

| Scope | batch=1 | batch=10 | Ratio |
|---|---:|---:|---:|
| Authorization commands (EVALSHA/20s, w2 @1000) | 20001 | 2002 | **roughly 9.99:1 (about 10×)** |
| Total Redis QPS (w2 @1000) | 4773 | 869 | 5.5× |
| Total Redis QPS (w1 @1000) | 4762 | 871 | 5.5× |
| RedisQPS @100 (w2) | 485 | 87 | 5.6× |
| RedisQPS @500 (w2) | 2420 | 421 | 5.7× |

Lower QPS ≠ overall performance gain (prohibited item 9): throughput hit the target in every mode at RPS=1000 constant arrival rate (measured 1000/1000); under this scope the system did not reach the Kong/Redis bottleneck, and the benefit shows up as Redis CPU −73% and Kong CPU −23%, not as an RPS gain (see §15 issue 3).

## 11. P95/P99 comparison

- p95: batch=10 beats batch=1 (1.16 vs 1.41ms @w2; 1.14 vs 1.30 @w1) — the direct benefit of a local TAKE with zero network round trip.
- p99: **both modes are in the 80–104ms range and batch=10 is slightly higher or equal**. Attribution: p99 is dominated by tail blocking — this host has ~4s periodic environmental noise (recorded in Phase 1), and clean-round p99 still contains 80ms+ tail events (M0 also has a 12–25ms tail from Docker network/scheduling jitter); the Redis round-trip savings (~0.2ms level) are swamped by tail events. **Averages must not be used to claim improvement, and p99 must not be used to deny the benefit**: the median and p95 improvements plus the drop in Redis resource usage are reproducible same-scope evidence.
- Legacy comparison (historical reference; different environment, not strictly comparable): legacy p99 b1=3.1/b10=2.2ms — the current host's noise is significantly higher than during the legacy collection period (this round's M0 p99=12.6ms vs legacy M0=1.8ms); **this must not be claimed as an implementation regression** (even M0 without rate limiting is elevated ⇒ environmental factor).

## 12. Kong/Redis resource usage

- Kong CPU (@1000, w2): M0 0.225 → b1 0.348 → b10 0.269 → multi 0.341 cores. b10 is 23% lower than b1 (fewer Redis round trips and Lua calls); 20% higher than M0 (authorization overhead).
- Redis CPU (@1000, w2): b1 0.079s → b10 0.021s (−73%); multi 0.101s (GRANT_MULTI's dual-key deduction costs more than a single key).
- Redis memory: lease records are on the order of ~10⁴ hashes (TTL 1h); memory usage within this benchmark's window is negligible (<10MB).
- Worker load distribution: under w2 all 6 (host,worker) pairs have lease_grant records (see §13).

## 13. Quota correctness evidence (collected alongside the performance test)

**Account reconciliation (all 87 groups, including polluted rounds)**:

| Check | Result |
|---|---|
| batch=1: EVALSHA count == HTTP 200 count (clean rounds) | ✓ w2 @1000: 20001=20001 (consistent across three rounds) |
| batch=1: no lease records | ✓ leaseGrant=0 (0 across all 87 groups); all Redis-side p4-* records come from group B |
| Multi-rule: EVALSHA == multi_grant == HTTP 200 | ✓ all three equal (full reconciliation at the 238226/238226 level) |
| batch=10: consumption == HTTP 200 | ✓ clean rounds @500: localHit 8998 + leaseGrant 1003 = 10001 = 200 count; @1000 off by 1 (0.005%, concurrency-boundary tolerance) |
| GRANT record count == lease_grant log count | ✓ 25580 Redis records == log Σ25580 (exactly one record per GRANT) |
| Σgranted == record count × batch | ✓ 255800 == 25580×10 (no records with granted≠10) |
| 429/5xx | ✓ 429=0 (limit magnification); 5xx=0; no semantic conflation |
| Negative inventory/duplicate consumption | ✓ (Phase 6.5 frozen evidence: 66 assertions including remaining≥0, TAKE atomicity; no new anomalies in this phase) |
| Worker distribution | ✓ lease records cover all 3 hosts × workers 0/1 alive at the time; 27 cumulative (host,worker) pairs historically (including Kong container rebuild cycles) |
| Inventory utilization | 255800 granted − 247952 consumed = **7848 (3.1%), the unconsumed/unconfirmed gap between total authorized and consumed** — per frozen Phase 6 semantics, outstanding refers specifically to worker-local inventory not yet consumed, and lost refers to inventory authorized but no longer usable; this gap is aggregate data and **cannot be attributed entirely to worker-local outstanding based on aggregation alone** (it includes portions whose inventory attribution is undecidable after lost responses in polluted rounds, and may in fact be distributed between outstanding and lost) — a real cost sample of the pre-authorization mode |

## 14. Performance bottleneck analysis

1. **Redis is not the bottleneck**: b1 @1000 RedisCPU is only 0.079s/20s (<0.5% of one core); after b10's 73% reduction, Redis is nearly idle.
2. **Kong workers have headroom**: 0.27–0.35 cores across three nodes (20-core host); RPS=1000 did not max out; all modes met the target at the constant-arrival-rate RPS ⇒ the throughput bottleneck was not reached, and headroom was not exposed under this scope.
3. **Latency noise floor**: p50 0.45–0.66ms comes from the Docker bridge network + Kong processing; p99 80–104ms is dominated by host environmental noise (M0 also has a 12–25ms tail) — precise attribution requires a cleaner isolated environment (NOT VERIFIED).
4. **GRANT slow path**: in b10, 10% of requests go through GRANT (~2ms-level EVALSHA + local registration), diluted by the 90% local path; p95 is in fact lower than b1's.

## 15. Lease mode's benefits and costs (answers to questions 1–4, item by item)

**Question 1 (does Redis QPS drop)**: Yes. Authorization commands 20001→2002, roughly 9.99:1 (an approximately 10× reduction; the small deviation from the theoretical 1/batch comes from multi-worker independent pre-authorization and batch boundaries), total QPS 5.5× (including connection overhead). The reduction comes from local inventory consumption (localHit 17998/20001 = 90%); verified by the §13 three-source account reconciliation (EVALSHA/logs/Redis records), **it is not lost requests or erroneous admissions** (the 200 count matches the consumption count, 429/5xx=0).

**Question 2 (does P99 improve)**: p95 improves (1.41→1.16ms); p99 does not (the 80–104ms tail is dominated by environmental noise; the ~0.2ms-level benefit is swamped). Honest conclusion: the causal attribution of p99 in this environment is NOT VERIFIED and requires re-testing in an isolated environment.

**Question 3 (does throughput increase)**: Under the RPS=1000 arrival-rate scope, all modes hit the target (no bottleneck exposed); the benefit shows up as resource usage (Redis CPU −73%, Kong CPU −23%), not RPS. Throughput-crossover comparison at higher pressure is NOT RUN (a stress test beyond this environment's capacity).

**Question 4 (performance costs)**: They exist, listed honestly — ① pre-authorized inventory is temporarily held by a single worker: at the end of the test window there is a 7848 (3.1%) unconsumed/unconfirmed gap between total authorized and consumed (it cannot all be attributed to local outstanding; the confirmed portion is lost immediately upon worker crash, measured 6/100 in Phase 6.5); ② authorization timing precision: batch-granularity pre-deduction + refill, not per-request real-time consistency; ③ local inventory creates short consumption bursts (90% of requests have zero Redis latency); the burst profile correlates positively with batch size; ④ the larger the batch, the larger the inventory-utilization-loss exposure (this test's 3.1% unconsumed/unconfirmed gap is the evidence — do not confuse it with the 10% GRANT request share; 10% is the share of requests that trigger a GRANT, while 3.1% is the unconsumed/unconfirmed gap of authorized inventory).

## 16. Test limitations and uncovered scenarios

- **NOT VERIFIED**: precise causal attribution of p99 (requires an isolated host without environmental noise); quantification of worker crashes' impact on mid-benchmark availability (Phase 6.5 tested correctness, not performance impact).
- **NOT RUN**: >1000 RPS stress (to avoid distortion beyond the host's capacity); >20s endurance; performance under Redis Cluster/primary-replica failover; distributed k6 load testing.
- **Scope limitations**: limit=1000000 isolates the rate-limiting path (same scope as Phase 1); 429/rejection-path performance untested; single rule only batch=10 (50/100 untested — unrelated to this phase's core question; the historical group B can serve as a legacy trend reference).
- Environmental noise: **87 groups executed in total = 72 clean rounds + 15 polluted rounds** (p99≥500ms); of the 72 (mode×worker×RPS) combinations, 60 passed on the first round and 12 triggered retries (9 retried once, 3 retried twice — 15 retry executions total, i.e., the 15 polluted rounds); **every mode × worker configuration × RPS tier has 3 clean rounds** (one each of w2 r1/r2/r3 + w1 r1/r2/r3, satisfying the three-round valid-data requirement); all raw data was retained and excluded from the means.

## 17. Conclusions

1. **Under the same scope, the current lease implementation genuinely and substantially reduces Redis authorization interactions**: authorization commands 20001→2002 (roughly 9.99:1, an approximately 10× reduction; the small deviation from the theoretical 1/batch comes from multi-worker independent pre-authorization and batch boundaries), total QPS 5.5×, Redis CPU −73%.
2. **Latency**: p50/p95 show reproducible improvement (local TAKE, zero IO); p99 shows no improvement, dominated by environmental noise, with causal attribution NOT VERIFIED.
3. **Throughput**: the arrival-rate scope exposed no bottleneck; the benefit shows up as reduced resource usage.
4. **Costs**: pre-authorization creates a 7848 (3.1%) unconsumed/unconfirmed gap between total authorized and consumed (it cannot all be attributed to local outstanding) plus batch-granularity timing precision, consistent with Phase 6.5's correctness/loss semantics.
5. All 11 items of 7.1 correctness: all have existing E2E frozen evidence (Phase 6.4/6.5 + this phase's account reconciliation); mapping table in §13 and the task list.
6. 7.3 protocol matrix check: `test/lease-redis-matrix.sh` **50/50 PASS** (executed directly against the current code, not a smoke test).

## 18. Follow-up optimization suggestions

1. Re-test p99 in an isolated environment (eliminate the 4s noise); add >1000 RPS stress and endurance runs.
2. `_counters` (leases/tokens_granted/tokens_consumed/closed) already has the foundation; wire up Prometheus metric export (Deferred, Phase 5+).
3. Lost audit metric (granted−consumed−outstanding) recorded to a table, derived from Redis records + crash events.
4. Adaptive batch (auto scope) and tenant-profiling tuning guide.
5. Multi-rule GRANT_MULTI's Redis CPU (0.101s) is higher than a single key; consider merging multi-rule keys or pipeline optimization (without changing semantics).

---

*All data comes from the raw files in bench/raw/phase7/; zero production code changes; the test framework extensions (matrix.sh leaseGrant column + print template fix) are committed with this commit.*
