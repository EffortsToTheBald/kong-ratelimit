# PHASE2_REVIEW — EVALSHA Script Management Review and Acceptance

> Review subject: `e4dd6c8 feat: add evalsha script management` + `b700417` (checklist sync)
> Core code: `lib/redis.lua`; unit tests: `test/evalsha-unit.sh/.lua`; performance: `bench/matrix.sh`, `docs/results.md`, `bench/out/results-p2-*`
> Review basis: Phase 2 implementation spec constraints + Phase 2 Spec/Design/Tasks + Phase 1 baseline
> Review date: 2026-11-13

## 1. Review Scope

- `lib/redis.lua` diff: added script table (SCRIPTS) + `is_noscript_err` + `load_script` + an `evalsha` wrapper (lazy loading + NOSCRIPT reload retry exactly once); `grant()/grant_multi()` calls switched from `r:eval` to `evalsha`.
- **Zero-change re-check of business decision logic**: the diff contains no parse_*/refill/debit/state logic changes; dual-source consistency re-check of the four scripts — TOKEN_BUCKET ✓, GRANT_MULTI ✓ (empty diff).

## 2. Code Review Conclusions

### P0-1 EVALSHA Execution Safety — PASS

| Check Item | Evidence |
|---|---|
| LOAD triggered only on an explicit NOSCRIPT | `is_noscript_err` is an exact substring match (`find(err,"NOSCRIPT",plain)`); timeout/disconnection/ordinary error strings do not contain that word |
| Retry exactly once after LOAD; second NOSCRIPT fails | Unit tests 3/4; real integration (the CLIENT PAUSE timing race cannot stably construct "still NOSCRIPT after marking"; stub-based, see §7 boundary) |
| LOAD failure returns correctly, no retry | Unit test 5 |
| Timeout/disconnection does not trigger LOAD | Unit tests 6/7 (stub) + **real Redis error-string shape evidenced** (CLIENT PAUSE scenario measured `err="timeout"`, matching the stub input) |
| No re-execution after a successful debit | NOSCRIPT is a pre-execution error (when the Redis script cache misses, the script executes zero times) — semantics guaranteed by Redis; client-side misclassification is impossible |

**Real-integration supplementary verification (added this round)**: with CLIENT PAUSE 2500ms + client 500ms timeout, the wrapper received `err="timeout"` and the **script\|load count delta = 0** (a timeout is never misread as NOSCRIPT to trigger a reload) — real Redis behavior evidence a stub cannot provide.

### P0-2 Redis Node Consistency — PASS (with verification boundary)

- SCRIPT LOAD and the EVALSHA retry **complete on the same connection `r`** (`load_script(r, entry)` followed immediately by `r:evalsha`).
- The Redis script cache is **instance-level** (not connection-level): after any connection on the same instance LOADs, EVALSHA works from other connections in the pool (the resty pool is keyed by host:port+db; this deployment is a single instance ⇒ no cross-node issue).
- **Verification boundary (declared as-is)**: the current deployment is a single Redis instance (standalone). **Cluster/multi-node script caching is per-node; not verified and not claimed as supported this phase** (recorded in Design Deferred). If host resolution ever drifts to a different instance, the NOSCRIPT self-heal path backstops (re-LOAD).

### P1-3 Multi-Worker and Lazy Loading — PASS

- Worker isolation: OpenResty gives each Worker an independent Lua VM; `SCRIPTS` module state is naturally per-Worker.
- State race analysis: concurrent requests on the same Worker lazy-load simultaneously ⇒ two `SCRIPT LOAD`s (idempotent; same src ⇒ same SHA1) ⇒ `entry.sha` double-written with the same value, no contamination.
- Load failure leaves no negative cache: `entry.sha` stays nil ⇒ the next call retries LOAD; recoverable.
- Real evidence: after FLUSH on three nodes, miss counts match the request distribution (kong1=3/kong2=1/kong3=1, empirical proof of independent multi-Worker lazy loading); E2E self-heal on both paths (token_bucket/grant_multi).

### P0-4 Original Rate-Limit Semantics — PASS

- Script text untouched (empty dual-source diff) ⇒ TOKEN_BUCKET debit/refill semantics and GRANT_MULTI all-or-nothing semantics unchanged.
- `grant()/grant_multi()` untouched beyond the call style; `parse_*` defensive validation untouched; fault branches (503/degraded) untouched.
- Regression: quota batch=1 exactly 100 ✓, dims.sh 8/8 ✓, rules.sh 14/14 ✓.

## 3. Issue List

| Level | Issue | Disposition |
|---|---|---|
| P0 | none | — |
| P1 | none | — |
| P2-1 | Error category passed through as strings (not structured noscript/definite/uncertain); Phase 3's GRANT/RETURN retry strategy needs structured classification | Recorded as a Phase 3 input (classification by error string wrapped at the call layer at that time); no scope expansion this phase |
| P2-2 | One process violation: when the `-T` argument patch was not fully in place, a Phase 2 dry run overwrote the working copy of `bench/out/results-p1-w2-notice-ip.md` | Recorded in docs/results.md process notes; authoritative data (docs/results.md + bench/raw/phase1/) not lost |
| P2-3 | `test/evalsha-unit.lua` had data errors in three cases (NOSCRIPT mistakenly written as a return value; LOAD-failure case mistakenly pre-set a cached SHA), producing 3 FAIL on the first run, 8/8 after correction | Fixed (errors in the test itself, not implementation defects) |

## 4. Fix Content

**No P0/P1 fixes**. This round added one real-integration verification script fragment (CLIENT PAUSE timeout classification, see §2/§7); production code untouched.

## 5. Test Execution Results

| Test | Type | Result |
|---|---|---|
| `test/evalsha-unit.sh` (8 cases: lazy loading/NOSCRIPT self-heal/second NOSCRIPT/LOAD failure/timeout not triggered/disconnection not triggered/post-lazy-load timeout/direct cached call) | stub unit | **PASS 8/8** |
| SCRIPT FLUSH → batch=1 path self-heal (200 + warn log) | real Redis E2E | **PASS** |
| SCRIPT FLUSH → multi-rule path self-heal (200 + warn log grant_multi) | real Redis E2E | **PASS** |
| Multi-Worker independent lazy loading (miss counts across three nodes) | real Redis E2E | **PASS** |
| CLIENT PAUSE timeout classification (timeout string + script_load delta=0) | real Redis integration | **PASS** |
| CLIENT PAUSE timing race (constructing "still NOSCRIPT after marking") | real Redis integration | **NOT RUN** (the two-connection arrival-order race cannot be stably constructed; behavior covered by stub 4, recorded as a verification boundary) |
| quota.sh batch=1 (100/350/0) | real Redis regression | **PASS** |
| dims.sh (8 assertions) | real Redis regression | **PASS** |
| rules.sh (14 assertions) | real Redis regression | **PASS** |
| GRANT_MULTI dual-source diff | static | **PASS** |

## 6. Performance Comparison Conclusion

Clean matched-attempt comparisons under the same conditions (k6/params/rate-limit config/Worker=2/IP direct/duration 20s, log level split into notice/error segments) (@1000 RPS):

| Scenario | Metric | EVAL (Phase 1) | EVALSHA (Phase 2) |
|---|---|---|---|
| A batch=1 | p50/p95/p99 ms | 0.65 / 1.26 / 3.08 | 0.59 / 1.11 / 1.50 |
| A batch=1 | RedisQPS / RedisCPU / KongCPU | 4865 / 0.043s / 0.334 cores | 4732 / 0.077s / 0.268 cores |
| C multi-rule | p50/p95/p99 ms | 0.84 / 1.59 / 2.80 | 0.63 / 1.18 / 1.55 |
| C multi-rule | RedisQPS / RedisCPU / KongCPU | 3830 / 0.099s / 0.330 cores | 7814 / 0.096s / 0.300 cores |
| Transport | GRANT_MULTI per call | 1982 B | 40 B (49×; 200 calls 387KB→8KB) |

- p99 improved (A 3.08→1.50, C 2.80→1.55), but **the magnitude lies within environment noise and sampling fluctuation** (the reverse fluctuation of RedisCPU 0.043→0.077 is one such example); **no statistically significant latency benefit is claimed**.
- **Certain benefit**: script transport bytes down 49× (this gap amplifies in cross-datacenter/public-network deployments — a microbenchmark result, not extrapolated as a 49× overall performance gain).
- Redis QPS/CPU/Kong CPU comparable (within sampling noise).
- EVALSHA count = request count 1:1, SCRIPT_LOAD = 0 (steady state), EVAL = 0 ✓.

## 7. Unverified Boundaries and Residual Risks

1. **Redis Cluster/multi-node**: NOSCRIPT behavior with per-node script caching unverified (Deferred; single-instance declaration for now).
2. **A real construction of "still NOSCRIPT after retry"**: depends on the race between LOAD success and a subsequent NOSCRIPT, cannot be stably constructed (covered by stub 4; the real trigger path = a nanosecond race between FLUSH and the retry).
3. **Structured error categories** (P2-1): needed by the Phase 3 GRANT/RETURN retry strategy; handled then.
4. **Host environment noise** (Phase 1 finding 3) persists (this round's Phase 2 notice segment had 1 contaminated re-run; the mechanism worked).
5. **`_M.scripts` exposure**: diagnostic/test use only; no production-path dependency.

## 8. Final Acceptance Conclusion

**PASS**

- No P0/P1 issues; all three P2 items recorded (1 carried as a Phase 3 input, 1 process record, 1 fixed).
- The correctness evidence chain is complete: stub classification logic 8/8 + real Redis E2E self-heal (both paths/multi-Worker) + real Redis timeout classification (script_load delta=0) + full regression green.
- Performance data is real, conditions consistent, no selective filtering (RedisCPU fluctuation recorded as-is).
- The single-instance boundary and the Cluster unverified item are declared as-is.
