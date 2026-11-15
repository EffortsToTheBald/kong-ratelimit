# Phase 6.4 Report: Full Regression and Fault Dual-Path Verification

- **Date**: 2026-11-13 (v2 revised edition)
- **HEAD before execution**: `f73c0a8` (initial 6.4); workspace contains only the test/report files permitted this round
- **Nature of this phase**: verification and blocking fixes only, zero production code changes
- **commit**: `test: tighten phase6.4 recovery and script cache evidence`

## 0. v2 Test Evidence Correction Record (contents of this revision)

### Correction 1: SCRIPT EXISTS check in script-cache-selfheal-e2e.sh

- **Problem**: the initial version used `redis-cli -x SCRIPT LOAD` to generate a sha and then checked EXISTS — even if the plugin had not completed NOSCRIPT self-healing, the test itself would load the script into the cache, polluting the check result
- **Fix**: extract the embedded script text from `redis.lua` → compute via the `sha1sum` method (Python `hashlib.sha1`) → check `SCRIPT EXISTS` directly, **never executing SCRIPT LOAD before the check**
- **Key detail (discovered during v2)**: Lua strips the first newline immediately following a long bracket `[[`; the plugin's actual src is the text after that first-line newline is stripped. The initial extraction (including the first-line newline) computed a sha that did not match the plugin's sha (exposed empirically by GRANT_LEASE EXISTS=0). Fixed by stripping the first-line newline before computing
- **Additional discovery (made during v2)**: immediately after FLUSH, a request to the original lease route may hit the worker's local inventory ⇒ zero Redis ⇒ grant_lease never triggers the NOSCRIPT reload (empirical: TOKEN_BUCKET/GRANT_MULTI EXISTS=1 while GRANT_LEASE EXISTS=0). Fixed by issuing a **new ns and new route** after FLUSH (new fingerprint ⇒ new pool ⇒ first request must GRANT)
- **Measured after the fix**: all three scripts have EXISTS=1 and match sha1sum ⇒ the extracted text is byte-for-byte identical to the plugin src ✓ (shas: `c95375…` / `eed403…` / `f89b62…`)

### Correction 2: R2 scenario in fault-recovery-e2e.sh

- **Problem**: the initial version fired 2 concurrent requests in R2 but asserted at most 1 lease record within the timeout window — two independent requests each authorized once can produce 2 records, so the assertion does not hold (it failed to distinguish duplicate requests within a single request vs. independent requests each being authorized)
- **Fix**: R2 simplified to a single-request scope: PAUSE 6s → single request 503 → PAUSE expires → record count ≤1 (0 allowed: Redis may have already executed before the timeout) → new independent request 200 remaining=9 → increment exactly +1; concurrent-race verification deferred to Phase 6.5
- **Test infrastructure issues discovered during v2 (not production code issues)**:
  1. During R1's downtime, each Kong worker's OpenResty DNS cache retained a failed `redis` host resolution (caches are per-worker), so recovery assertions occasionally hit the stale cache ⇒ 503 (semantically correct but recovery had not yet happened). Fix: **poll the target route until the first 200** — connection-refused-class 503s are deterministic zero-write facts (the request never reached Redis), so the first 200 is the recovery request, authorizing exactly once, and the "record count exactly 1" assertion therefore holds deterministically
  2. The standalone probe route used for liveness checks in the initial version could only prove a single worker was reachable; it could not cover other workers' stale DNS caches. Removed, replaced by directly polling the target route
- **Measured after the fix**: 3 consecutive rounds all green (13/0, 13/0, 12/0 — 12 for the last round without the intermediate recovery-polling attempts); a stale DNS 503→recovery was genuinely reproduced once during the runs and all assertions held

### Initial (f73c0a8) vs. v2 results

| Test | Initial result | v2 result after fixes | Notes |
|---|---|---|---|
| script-cache-selfheal-e2e.sh | PASS 14/14 (including the polluted EXISTS check) | **PASS 15/15** (unpolluted) | The initial EXISTS results are void (polluted scope); v2 additionally found and fixed two blind spots: the extraction method and the inventory-hit path |
| fault-recovery-e2e.sh | PASS 12/12 (R2's concurrent assertion did not hold) | **PASS 13/12/13 (three consecutive rounds all green)** | R2 reduced to a single request; R1 scenario unchanged with target-route polling added (timing hardening) |
| evalsha-unit.sh | PASS 8/8 | PASS 8/8 (re-run) | No changes |
| handler-fault-e2e.sh | PASS 26/26 | PASS 26/26 (re-run) | No changes |
| Rest (quota/dims/rules) | See §2–§5 | Quoting the initial measured results (this round did not touch those paths) | Initial data remains valid |

## 1. Test environment

- Three nodes `kong1/2/3` (2 workers each) + a single-instance `redis`; Config API :8031/:8011/:8021, proxy :8030
- Measurement method: `CONFIG RESETSTAT` + `cmdstat_evalsha:calls` from `INFO commandstats` (the window contains only that benchmark round + config issuing; measured config issuing contributed 0 EVALSHA calls)

## 2. quota.sh batch=1 (Spec scenario 1: batch=1 strict path unchanged)

| Round | Result | EVALSHA calls | Lease records |
|---|---|---|---|
| Round 1 | allowed=100 limited=350 other=0 total=450, **exactly equal to quota 100 PASS** | — | — |
| After RESETSTAT | allowed=100 limited=350 other=0 PASS | **exactly 450** (1 per request) | **0** |

- Conclusion: batch=1 EVALs per request, does not use the local lease; 450 requests with exactly 100 allowed, consistent with the Phase 1 anchor; Spec's "no lease records in Redis" ✓
- Anchor changes: none

## 3. quota.sh batch=20 (Spec scenario 3: single rule with batch>1 uses leases)

| Round | allowed | Lease records | EVALSHA calls |
|---|---|---|---|
| Round 1 | **80** ∈ [40,100] PASS | 5 records (each granted=20, status=OPEN) | — |
| Round 2 | 100 (100% utilization PASS) | — (355 calls in window) | **355** |

- **Account reconciliation (355 = 350 + 5)**: 450 requests = 95 pure local TAKEs (zero Redis, = 100 allowed − 5 first-pool GRANTs) + 5 granted-GRANTs + 350 denied-GRANTs (inventory exhausted ⇒ request rejected by the bucket ⇒ granted=0 ⇒ 429; frozen design "exhaustion triggers a new lease request")
- No over-admission (allowed ≤ limit); batch GRANT authorization + local TAKE + re-request on exhaustion ✓; denied-GRANTs are the miss path with one EVAL (global consistency is guaranteed by the GRANT script's bucket check), not "a Redis operation per request"

## 4. dims.sh regression

**PASS 8/8**: IP / Path / Client ID / Header and all existing dimensions green — dimension-value isolation, correct bucket hits, header configuration taking effect, config fingerprints not breaking dimension isolation, and the batch>1 lease path not breaking per-dimension rate-limiting semantics

## 5. rules.sh regression (Spec scenario 2: multi-rule path unchanged)

**PASS 14/14**, including the core scenario "pre-seeded one empty and one non-empty ⇒ 429 and both buckets' tokens unchanged"; multi-rule all-or-nothing, legitimate admissions, and 429/Retry-After semantics all green; the multi-rule algorithm and Lua protocol were not modified; multi-rule zero-lease-records is covered jointly by the 6.2 group's `algorithm-lease-e2e.sh` assertions and this round

## 6. Fault dual paths

### 6.1 handler-fault-e2e.sh (PASS 26/26, re-run in v2)

- Connection refused: both batch=1 and batch>1 yield 503 (ft=false) / degraded (ft=true); faults are never disguised as 429 ✓
- CLIENT PAUSE 6s timeout: batch=1 enters the existing fault branch; batch>1 uncertain outcome ⇒ 503, no duplicate request, no local inventory registration, no disguised token shortage ✓
- Both workers [0,1] hold inventory ✓

### 6.2 fault-recovery-e2e.sh (after v2 fixes, PASS 13/0, 13/0, 12/0 — three consecutive rounds all green, §7.3)

- R1 connection refused → recovery (scenario unchanged; recovery assertions hardened via target-route polling): 503 during the outage ⇒ recovery ⇒ 200 remaining=9; **exactly 1 lease record for that ns** (zero writes during downtime + single authorization at the first 200, no duplicate authorization)
- R2 timeout → recovery (single-request scope): PAUSE 6s ⇒ single request 503 (no retry, no disguised 429); PAUSE expires ⇒ record count 0 ≤1 (0 or 1 allowed); new independent request 200 remaining=9; **increment exactly +1** ⇒ no duplicate authorization; a stale DNS 503→recovery was genuinely reproduced once during the runs and all assertions held
- Uncertain outcomes do not register local inventory and do not duplicate requests (6.2 group semantics) are covered by the handler-fault-e2e timeout scenario

## 7. EVALSHA cache-loss self-healing (§8)

### 7.1 script-cache-selfheal-e2e.sh (after v2 fixes, PASS 15/15)

- 200 before FLUSH in each of the three modes (lazy-loaded EVALSHA working normally)
- After `SCRIPT FLUSH`: batch=1 and multi-rule each 200 per request; the **new ns lease route** 200 on first request (guarantees grant_lease necessarily triggers NOSCRIPT; the local-inventory-hit path does zero Redis and does not trigger the reload — the blind spot found and fixed in v2)
- `SCRIPT EXISTS` (sha1sum method, zero SCRIPT LOAD pollution): all three scripts =1 ⇒ the plugin self-healed and reloaded, and the extracted text is byte-for-byte identical to the plugin src (Lua first-line-newline stripping empirically verified)
- Logs contain no `script still missing after reload` / `script load failed`

### 7.2 Static unit test evalsha-unit.sh (PASS 8/8, re-run in v2)

- NOSCRIPT ⇒ LOAD ⇒ exactly one retry; NOSCRIPT again after retry ⇒ explicit failure, no second LOAD (no infinite retries)
- **Timeout ⇒ no LOAD triggered** (never treated as NOSCRIPT)
- LOAD failure and other error paths do not break Phase 2 behavior

## 8. Per-scenario verification of the Spec's applicability boundaries (verbatim from spec.md `Lease mode applicability boundary` Requirement)

| # | Scenario definition (verbatim) | Expected behavior | Test script | Actual result | Meets Spec |
|---|---|---|---|---|---|
| 1 | **batch=1 strict path unchanged**: "re-run the Phase 1 baseline with a batch=1 configuration (450 requests, exactly 100 allowed) plus the fault dual paths" | Results consistent with existing anchors; no lease records in Redis | quota.sh -b 1 + handler-fault-e2e.sh + RESETSTAT method | 450 requests → exactly 100/350/0 consistent across both rounds; EVALSHA exactly 450; lease records 0; fault dual paths all 26 assertions green | ✓ |
| 2 | **Multi-rule path unchanged**: "re-run all rules.sh scenarios" | All green and no lease records in Redis; the "one empty one non-empty ⇒ 429 and both buckets unchanged" semantics intact | rules.sh (14 scenarios) + algorithm-lease-e2e.sh multi-rule zero-lease assertions | PASS 14/14; core scenario ✓; multi-rule zero leases ✓ | ✓ |
| 3 | **Single rule with batch>1 uses leases**: "issue requests with a batch=20 configuration" | The first request creates a lease via GRANT (lease record visible in Redis, status OPEN); subsequent requests consume via local TAKE; no per-request Redis operations | quota.sh -b 20 + RESETSTAT account reconciliation | Lease record OPEN granted=20; 95 pool-hit requests with zero Redis; re-request on exhaustion ✓ | ✓ |

No Spec acceptance criteria were rewritten; the implementation has no conflicts with the frozen Spec.

## 9. PASS / FAIL / NOT RUN statistics (v2)

| Item | Result | Basis |
|---|---|---|
| quota.sh -b 1 (two rounds + account reconciliation) | PASS | Actually executed (measured in the v1/f73c0a8 report; not re-run this round: no changes to the batch=1 path) |
| quota.sh -b 20 (two rounds + account reconciliation) | PASS | Actually executed (same as above) |
| dims.sh | PASS 8/8 | Actually executed (same as above) |
| rules.sh | PASS 14/14 | Actually executed (same as above) |
| handler-fault-e2e.sh | PASS 26/26 | **Actually re-run in v2** |
| fault-recovery-e2e.sh | PASS 13/0, 13/0, 12/0 | **Actually executed ×3 after v2 fixes** |
| script-cache-selfheal-e2e.sh | PASS 15/15 | **Actually executed after v2 fixes** |
| evalsha-unit.sh | PASS 8/8 | **Actually re-run in v2** |
| Phase 6.1–6.3 suites (lease-unit 25 / algorithm-lease-unit 17 / algorithm-lease-e2e 15 / config-isolation 15+14) | Quoting verified 6.1–6.3 results | Static code inspection (not re-run this round; the related implementation had zero changes) |
| **Total** | **FAIL 0**; v2 measured assertions (most recent round): 26 + 12 + 15 + 8 = **61 PASS**; the initial measured records for quota/dims/rules (quota two rounds, dims 8, rules 14) remain valid | |
| NOT RUN | Phase 6.5 concurrency and exception E2E, 6.6 final delivery | Not executed |

(Statistical note: fault-recovery went three consecutive rounds 13/13/12 all green; the total takes the most recent round's 12; per-round details are archived in §6.2.)

## 10. Issues found and fix record

- **Zero production code changes** (both corrections were test-evidence scope fixes)
- Test blind spots found and fixed during v2 (all were test issues themselves, not implementation regressions):
  1. The EXISTS check polluted itself via SCRIPT LOAD → switched to the sha1sum method
  2. Lua long-bracket first-line newline stripping caused the extracted sha to differ from the plugin src → strip before computing
  3. After FLUSH, the lease route hit local inventory ⇒ grant_lease did not trigger the reload → new ns and new route force a GRANT
  4. R2's concurrent-request record-count assertion did not hold → reduced to a single request (concurrency verification deferred to 6.5)
  5. Stale resolutions lingering in OpenResty DNS caches, which are per-worker → poll the target route until the first 200 (connection-class 503s are deterministic zero-write)
- quota b20's two rounds with allowed=80/100: legitimate range fluctuation from worker assignment differences, not a regression

## 11. Conditions for entering Phase 6.5

- batch=1 zero regression ✓; batch>1 lease path correct ✓; dimensions/multi-rule zero regression ✓; fault dual paths match existing semantics ✓ (actually passing after the fixes); EVALSHA self-healing empirically unpolluted for all three scripts ✓; all three Spec scenarios satisfied ✓
- **Conclusion: conditions for entering Phase 6.5 (concurrency and exception E2E) are met, premised on the tests actually passing after the v2 fixes**
