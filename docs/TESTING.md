# Testing Guide (Run Index and Prerequisites)

> Tests are divided into four layers: **resty protocol-level unit tests** (executed inside
> the kong1 container), **Redis Lua protocol matrix** (run directly via redis-cli),
> **real-stack E2E** (real Kong + Redis + HTTP), and the **performance matrix** (k6).
> Assertion counts per script follow the phase reports in `docs/reports/`; this document
> only gives run instructions and prerequisites, and **the historical PASS counts do not
> mean a single command reproduces everything** — prepare the environment per the
> prerequisites below and run each one individually.

## 0. Prerequisites

```bash
docker compose up -d            # 3×kong + redis + echo all healthy
curl -s http://localhost:8031/status          # kong1 admin plane 200
docker compose exec -T redis redis-cli ping   # PONG
```

- Unit-test scripts automatically `docker compose cp` into kong1 and execute with resty ⇒ the stack must be up first
- E2E scripts carry their own namespace/config push/precondition checks; some scripts
  stop/start redis or kill -9 Workers (auto-recovered after the run); **do not run them in
  parallel with other tests** (FLUSHDB/environment-interference risk; run serially)
- The performance matrix recreates Kong with `KONG_LOG_LEVEL=debug` by default (the
  statistics columns depend on it) and restores the compose default automatically at the end

## 1. resty Protocol-Level Unit Tests (inside the kong1 container)

| Command | Coverage | Most recent all-green assertion count |
|---|---|---|
| `bash test/lease-unit.sh` | Lease Manager: TAKE/registration/CLOSED/four-way classification/accounting conservation/non-yield | 25 |
| `bash test/algorithm-lease-unit.sh` | Three-mode decision matrix (transport stub driving the real check_lease) | 17 |
| `bash test/config-isolation-unit.sh` | Policy fingerprint five dimensions + local Pool isolation | 15 |
| `bash test/evalsha-unit.sh` | EVALSHA management: NOSCRIPT retried exactly once / timeout does not trigger LOAD | 8 |

## 2. Redis Lua Protocol Matrix

| Command | Coverage |
|---|---|
| `bash test/lease-redis-matrix.sh` | GRANT_LEASE/RETURN_LEASE/GRANT_MULTI/TOKEN_BUCKET protocol-level 50 items (run directly via redis-cli; re-checked 50/0 during Phase 7) |
| `bash test/lease-grant-smoke.sh` | GRANT smoke test |

## 3. Real-Stack E2E (independent namespace per item, run serially)

| Command | Coverage |
|---|---|
| `bash test/handler-fault-e2e.sh` | Dual failure paths: stop redis / CLIENT PAUSE timeout; batch=1 and batch>1; two-Worker inventory (26 assertions) |
| `bash test/fault-recovery-e2e.sh` | Failure recovery: connection refused→recovered, CLIENT PAUSE→recovered; no duplicate authorization (12 assertions) |
| `bash test/concurrent-lease-e2e.sh` | Multi-Worker concurrent TAKE/GRANT, no global over-admission, Worker distribution (17 assertions) |
| `bash test/lease-exhaustion-e2e.sh` | Lease exhaustion → CLOSED → new GRANT; multiple Leases coexisting (11 assertions) |
| `bash test/worker-crash-e2e.sh` | kill -9 target Worker (inode→PID evidence) + inventory-loss accounting (16 assertions) |
| `bash test/lease-timeout-uncertain-e2e.sh` | GRANT timeout three states: not executed / executed but response lost / granted=0 (22 assertions) |
| `bash test/config-isolation-e2e.sh` | Config-change real-stack isolation (14 assertions) |
| `bash test/algorithm-lease-e2e.sh` | Lease-path real-stack behavior (15 assertions) |
| `bash test/script-cache-selfheal-e2e.sh` | NOSCRIPT self-heal of all three modes after SCRIPT FLUSH (15 assertions) |
| `bash test/lease-isolation.sh` | Lease isolation historical regression |

## 4. Bench Correctness Regression (bench/)

| Command | Coverage |
|---|---|
| `bash bench/quota.sh -l 100 -b 1 -p 150` | batch=1 multi-replica strict quota (450 requests, exactly 100) |
| `bash bench/quota.sh -l 100 -b 20 -p 150` | batch=20 interval [40,100] |
| `bash bench/dims.sh` | Seven-dimension regression (8 assertions) |
| `bash bench/rules.sh` | Multi-rule all-or-nothing, 5 scenarios (14 assertions) |

## 5. Performance Matrix

```bash
bash bench/matrix.sh                       # Default: BATCHES=10,50,100; RATES=100,500,1000; DUR=20s; debug level
bash bench/matrix.sh -b 10                 # batch=10 group only (Phase 7/8 spot-check basis)
bash bench/matrix.sh -w 1                  # Worker=1 (auto-recreates and restores at the end)
bash bench/matrix.sh -L notice             # notice level (statistics columns are 0 then, which is expected)
```

- Artifacts: `bench/out/results-<TAG>-w<W>-<level>-<rhost>.md` + k6 json `bench/out/<TAG>-w*.json`
- Collection: Redis commandstats/cpu, Kong log lines (**debug level required**), cgroup
  cpu.stat; contaminated runs (p99>500ms or RPS<95%) are auto-rerun up to 3 times, with
  all rounds kept
- **Official performance conclusions come from `docs/reports/PHASE7_PERFORMANCE_REPORT.md`**
  (raw data `bench/raw/phase7/`); any other single-round run is for behavior verification
  only and must not be mixed with Phase 7

## 6. Test Environment Cleanup

```bash
docker compose down -v                     # Full reset (stop/kill actions in E2E are auto-recovered by the scripts)
docker compose up -d --force-recreate kong1 kong2 kong3   # Run this before re-running after reloading plugin code
```

- Serial reminder: dims.sh/rules.sh FLUSHDB between scenarios; running them in parallel
  with E2E clears each other's state
- If an E2E script fails sporadically, re-run once before attributing cause (the host has
  a known ~4s environmental noise)

## 7. Historical Test Report Index

| Phase | Reports |
|---|---|
| Phase 0 | docs/PHASE0_REVIEW.md, docs/review-phase-0.md |
| Phase 1 | test/phase1-manual.md (historical basis: RL-DEBUG was at notice level then), docs/results.md (Legacy performance baseline) |
| Phase 2 | docs/PHASE2_REVIEW.md, test/phase2-manual.md |
| Phase 3 | docs/PHASE3_GROUP1_REPORT.md, reports/phase-3-multi-rule.md |
| Phase 4 | docs/PHASE4_WORKER_LEASE_REPORT.md |
| Phase 6 | docs/PHASE6_REQUEST_INTEGRATION_REPORT.md, docs/reports/PHASE6_3/6_4/6_5_REPORT.md |
| Phase 7 | docs/reports/PHASE7_PERFORMANCE_REPORT.md + bench/raw/phase7/ |
| Phase 8 | docs/reports/PHASE8_CLEANUP_PLAN.md, PHASE8_A_LEGACY_CLEANUP_REPORT.md, PHASE8_B_LOG_CLEANUP_REPORT.md |

**Historical basis note**: some steps in phase1-manual.md / phase2-manual.md depended on
RL-DEBUG logs that were at notice level at the time; the current hot-path RL-DEBUG has
been lowered to debug (Phase 8.2-B), so reproducing those log statistics requires
`KONG_LOG_LEVEL=debug`. Historical steps and conclusions are preserved as-is.
