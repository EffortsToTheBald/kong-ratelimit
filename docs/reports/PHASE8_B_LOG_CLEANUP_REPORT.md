# Phase 8.2-B Report: RL-DEBUG Request Hot-Path Log Cleanup

- **Date**: 2026-11-14
- **Baseline HEAD**: `226337e` (the Phase 8.2-A delivery fix commit)
- **commit**: `perf: reduce rate limit hot-path debug logging`

## 1. Log audit inventory (full, before changes)

| Log location | Marker/content | Level | Path | Trigger frequency | Test dependency | Action | Impact |
|---|---|---|---|---|---|---|---|
| algorithm.lua:287 | `[RL-DEBUG] multi_grant keys=...` | notice | hot path (multi-rule per request) | per request | matrix.sh multiGrant column | **downgrade to debug** | notice output volume ↓; statistics now collected at debug level |
| algorithm.lua:314 | `[RL-DEBUG] multi_reject keys=...` | notice | hot path (multi-rule rejection) | per 429 | no active script dependency | **downgrade to debug** | same as above |
| algorithm.lua:352 | `[RL-DEBUG] local_hit key=...` | notice | hot path (batch>1 local hit) | per locally consumed request | matrix.sh localHit column | **downgrade to debug** | same as above |
| algorithm.lua:379 | `[RL-DEBUG] lease_grant key=...` | notice | slow path (GRANT_LEASE) | per GRANT | matrix.sh leaseGrant column | **downgrade to debug** | same as above |
| algorithm.lua:408 | `[RL-DEBUG] lease_take_after_grant` | notice | slow path (TAKE after GRANT) | per GRANT | no direct column (behavioral assertion dependency) | **downgrade to debug** | same as above |
| algorithm.lua:457 | `[RL-DEBUG] redis_grant key=...` | notice | hot path (batch=1 per request) | per request | matrix.sh slowGrant column, phase1-manual.md (historical doc) | **downgrade to debug** | same as above |
| handler.lua:19 | `V1 lease mode (worker-private table...)` | notice | init path | 1 per startup | none | **keep notice** | necessary startup info |
| handler.lua:25 | `bad config: ...` | err | config error path | on exception | none | **keep err** | critical config errors |
| handler.lua:37 | `limiter unavailable, failing open` | warn | fault path | on exception | semantic observation | **keep warn** | degraded diagnosis |
| handler.lua:42 | `limiter unavailable, failing closed` | err | fault path | on exception | handler-fault-e2e assertion | **keep err** | fail-close diagnosis |
| handler.lua:54 | `429 key=... limit=... reject=...` | notice | hot path (only on 429) | per 429 | none (behavioral assertion) | **keep notice** (downgrade prohibited item) | deterministic rejection decision log |
| redis.lua:436 | `script cache miss (NOSCRIPT), loaded: ...` | warn | self-healing path | on NOSCRIPT | script-cache-selfheal assertion (negative) | **keep warn** (downgrade prohibited item) | self-healing diagnosis |
| algorithm.lua:274 | `redis grant_multi failed` | err | fault path | on exception | — | **keep err** | multi-rule fault diagnosis |
| algorithm.lua:375 | `lease grant failed (kind)` | err | fault path | on exception | fault-recovery/timeout log observation | **keep err** | explicit/uncertain classification diagnosis |
| algorithm.lua:404 | `lease take after grant returned NEED_GRANT` | err | defensive path | on exception | — | **keep err** | defensive branch diagnosis |
| algorithm.lua:454 | `redis grant failed` | err | fault path | on exception | handler-fault-e2e indirect | **keep err** | batch=1 fault diagnosis |
| lease.lua | (no log calls, grep-verified) | — | — | — | — | — | — |

**The local_fill log was deleted with Batch A's dead code block (it no longer exists).**

## 2. Level comparison before and after

- 6 `[RL-DEBUG]` sites in algorithm.lua notice → **debug** (level only; the `[RL-DEBUG]` marker, event names, and the key/grant/remaining fields and their order are **preserved verbatim**, with no new concatenation)
- All other logs (err/warn/notice) **untouched**

## 3. Test script dependency analysis and adaptation

- **Active E2E scripts (test/*.sh)**: full grep verification — **zero RL-DEBUG/local_hit/lease_grant/multi_grant dependencies** (only matrix.sh and the historical doc phase1-manual.md) ⇒ E2E needs no adaptation
- **matrix.sh**: statistics columns (localHit/slowGrant/leaseGrant/multiGrant) count `docker logs` substrings (level-agnostic) but require the log lines to be emitted ⇒ **default LOGLEVEL changed from notice to debug** (script header comment + table-reading note: at notice level the statistics columns are 0, which is expected and not request loss; performance comparisons need an explicit `-L notice`)
- **Unit test kong stub**: `kong.log` stub in algorithm-lease-unit.lua / config-isolation-unit.lua supplemented with `debug = function() end` (the original stub lacked debug ⇒ calls would error nil after the downgrade)

## 4. Changed files

| File | Changes |
|---|---|
| `lib/algorithm.lua` | 6 sites notice→debug (:287/314/352/379/408/457) |
| `bench/matrix.sh` | default LOGLEVEL=debug + comments/table-reading note |
| `test/algorithm-lease-unit.lua` | stub adds debug |
| `test/config-isolation-unit.lua` | stub adds debug |
| `docs/reports/PHASE8_B_LOG_CLEANUP_REPORT.md` | this report |

**Zero production semantics change**: rate-limiting algorithm/token bucket/Redis keys/fingerprints/Lua protocol/batch semantics/lease state machine/error handling/responses — untouched (only log levels and test stubs/collection configuration).

## 5. Test commands and actual results (all actually executed)

| Test | Result |
|---|---|
| `bash test/lease-unit.sh` | 25/0 |
| `bash test/algorithm-lease-unit.sh` | 17/0 (after stub adaptation) |
| `bash test/evalsha-unit.sh` | 8/0 |
| `bash test/config-isolation-unit.sh` | 15/0 (after stub adaptation) |
| `bash test/algorithm-lease-e2e.sh` | 15/0 |
| `bash test/config-isolation-e2e.sh` | 4-run history: 13/1, 14/0, 14/0, 14/0 (one intermittent failure on the first round, not reproduced; historical failing rounds recorded separately from the latest round's statistics; attribution NOT VERIFIED) |
| `bash test/handler-fault-e2e.sh` | 26/0 |
| `bash test/concurrent-lease-e2e.sh` | 17/0 |
| `bash test/lease-exhaustion-e2e.sh` | 11/0 |
| `bash test/worker-crash-e2e.sh` | 16/0 |
| `bash test/lease-timeout-uncertain-e2e.sh` | 22/0 |
| **Total (latest round: config-isolation-e2e taken as 14)** | **25+17+8+15+15+14+26+17+11+16+22 = 186 PASS / 0 FAIL** |

Semantic verification: 429/503 semantics, batch=1/batch>1/multi-rule, fault paths, crash semantics, exhaustion re-requests — all pass the corresponding E2E assertions.

## 6. Performance matrix spot check (p8bcheck, only verifies collection capability; not a formal performance conclusion)

`bash bench/matrix.sh -T p8bcheck -b 10` (default debug level; results table archived at `bench/raw/phase7/results-p8bcheck-w2-debug-redis.md`):

| Column | Clean-round measured | Verdict |
|---|---|---|
| localHit (b10 **@500** clean round a3) | 8998 | ✓ collection works |
| leaseGrant (b10 **@500** clean round a3) | 1003 (≈ requests 10001/10) | ✓ |
| slowGrant (b1 **@1000** clean round a2) | 20000 (that round had 20000 requests) | ✓ |
| multiGrant (multi **@1000** clean round a1) | 20001 | ✓ |
| EVALSHA (b1/b10/multi, respective clean rounds) | 20000 / 1003 / 20001 | ✓ |
| EVAL / SCRIPT_LOAD | 0 / 0 | ✓ |
| 429/5xx | 0/0 | ✓ |

- **Data-source correction (v2)**: this section initially miswrote "localHit 17998 / leaseGrant 2003 (b10 @1000)" — those numbers come from **p8acheck** (the Batch A spot check, notice level, the B-batch10 @1000 a1 row of `bench/raw/phase7/results-p8acheck-w2-notice-redis.md`: 17998/2003) and are unrelated to this section's p8bcheck; it was a round mix-up and has been deleted.
- **p8bcheck's archived raw data prevails**: B-batch10 @1000's three attempts were **all polluted by the 4s environmental noise** (measured RPS 902/952/959, p99 6101/3880/3950ms; localHit 12649/14977/15000, leaseGrant 1925/2152/1720 — the ratio still ≈1/10, collection capability confirmed but no clean round); b10's clean-round evidence is taken from **@500 a3** (8998/1003, raw row retained in the results table).
- The host's 4s noise was heavier this round; **not a performance conclusion, not mixed with Phase 7**.

## 7. Notice log count comparison

- **Before the fix (Batch A code, notice level)**: at least 1–2 RL-DEBUG lines per request (b10's local hits emit 1 local_hit line per request, b1 emits 1 redis_grant line per request, +2 lines on GRANT). Quantified evidence: ① Phase 7's collection scope itself depends on these lines (localHit 17998 lines/20s); ② a sample captured before the rebuild: `[notice] ... [RL-DEBUG] lease_grant ...` / `lease_take_after_grant ...` / `local_hit ...` (2026-11-14 12:58:49, docker logs kong1).
- **After the fix (notice level, current default)**: **RL-DEBUG output = 0** (10-request smoke test: docker logs adds only Kong access logs; kong1/kong2 full RL-DEBUG count = 0).
- **Debug level (explicitly enabled)**: events and fields complete (p8bcheck statistics isomorphic to Phase 7's notice scope).
- Retained fault-log verification: `limiter unavailable` / `lease grant failed` present in the logs after fault-class E2Es (err/warn level, 20 occurrences confirmed).

## 8. Retained fault log inventory

handler.lua:19/25/37/42/54 (notice init, err config, warn degraded, err fail-close, notice 429); redis.lua:436 (warn NOSCRIPT); algorithm.lua:274/375/404/454 (err ×4). The list matches the code line by line (§1).

## 9. Unverified items

- The residual impact of debug-level logs on high-concurrency throughput was not quantified (heavy noise this round, no clean comparison possible; the same root cause as Phase 7's NOT VERIFIED).
- config-isolation-e2e's single intermittent first-round failure was not reproduced (4-run record retained); attribution NOT VERIFIED.
- The RL-DEBUG operational instructions in the Phase 1 historical doc (phase1-manual.md) were not synced (historical record; by convention not a valid code reference; to be handled with Batch C's documentation work).

## 10. Core request-path semantics statement

**Unchanged**: rate-limiting decisions, Redis interactions, lease lifecycle, error handling and fault semantics, responses and status codes — this batch only **downgrades the level** of 6 hot-path debug logs from notice to debug (fields preserved verbatim) and syncs the statistics collection scope to debug level.

---

*Statistical scope: all numbers in this report come from actual execution output; the frozen Phase 6/7 reports and raw data are untouched.*
