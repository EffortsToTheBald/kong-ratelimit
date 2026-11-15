# Phase 8.1 Report: Final Cleanup Audit and Implementation Plan

- **Date**: 2026-11-14
- **Baseline HEAD**: `bc46c8c0fcaf8476f3544ffec0aa22a307fbe60c` (clean workspace, only the untracked `1113.json` session export)
- **Nature**: audit and planning only; **zero code/docs/config changes in this phase**

---

## 1. Current project status (capability vs. evidence)

| Capability | Status | Evidence |
|---|---|---|
| batch=1 per-request Redis authorization | Implemented with evidence | EVALSHA==request count (Phase 6.4 exactly 450, Phase 7 clean rounds 20001=20001), lease records 0 |
| Single rule batch>1 lease pre-authorization | Implemented with evidence | Phase 6.5 four scripts, 66 assertions (including same-worker attribution with inode→fd→PID checked three times); Phase 7 authorization commands 20001→2002 (roughly 9.99:1) |
| Multi-rule GRANT_MULTI all-or-nothing | Implemented with evidence | rules.sh 14/14 (one empty one non-empty ⇒ 429 with both buckets unchanged), Phase 7 three-way account equality |
| Fault dual path / timeout uncertainty / recovery | Implemented with evidence | handler-fault-e2e 26, fault-recovery 12, scenario A/B three-state distinction |
| Config fingerprint isolation | Implemented with evidence | config-isolation 15+14 |
| EVALSHA lazy-load + NOSCRIPT exactly-once self-healing | Implemented with evidence | evalsha-unit 8 + script-cache-selfheal 15 + Phase 7 SCRIPT_LOAD=0 (87 groups) |
| Concurrency safety / crash loss accounting | Implemented with evidence | lease-unit 25, worker-crash 16 (10=4+6, no takeover) |
| Performance (same scope) | Implemented with evidence | Phase 7 report + bench/raw/phase7/ (95 files) |
| Auto RETURN / idle scanner / max_lifetime / worker takeover / compensation | **Deferred, not implemented** | V1_SCOPE_ADJUSTMENT.md (the RETURN_LEASE Lua is ready but not wired) |
| Redis Cluster/HA, metric export, endurance | **Not implemented/not verified** | Phase 6.6 §14 production-readiness gap analysis |

## 2. Directory structure audit

```
kong/plugins/rate-limit-advanced/
├── handler.lua      (106 lines) access-phase decision exit: build_key→check→admit/429/503; no store/shared references ✓
├── schema.lua       config validation (rules/batch/redis etc.; no shared-dict-related fields ✓)
└── lib/
    ├── algorithm.lua (494 lines) decision core: build_key/fingerprint/check/check_lease/check_multi/rate_and_burst
    ├── lease.lua     (351 lines) worker-private lease manager: take/grant/classify_grant/_pools/_counters
    ├── redis.lua     (749 lines) Redis client: connect/set_keepalive/evalsha self-healing/token_bucket/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE (not wired)
    └── store.lua     (87 lines) [deprecation candidate] shared-dict aggregate inventory (the legacy batch>1 implementation)
bench/{common,matrix,quota,dims,rules,xff}.sh + k6/latency.js    performance framework (extended with the leaseGrant column in Phase 7)
test/*.sh|*.lua                                                   Phase 0–6.5 full regression + E2E
docs/ + docs/reports/                                             Phase 0–7 reports + integration report
openspec/changes/phase4-performance-and-lease-return/             frozen Spec/Design/tasks
```

Dependency graph: handler→algorithm→{lease,redis,store}; redis is independent; lease is independent (the redis client is injected via callbacks). **store's dependency is unidirectional and unique** (algorithm.lua:10).

## 3. Legacy code inventory (per-item reference analysis, not filename inference)

### 3.1 `lib/store.lua` (87 lines)

- **Code location**: the entire file (DICT_NAME="kong_rl", take/fill/dict_mode/degraded logic)
- **Current references**: the repo's only require = algorithm.lua:10; the only call = algorithm.lua:483 `store.fill(key, granted.granted - 1, ttl_s)`
- **On a live call path**: **No** — line 483 sits inside the `if batch > 1 and granted.granted > 1` branch, but `check()` already transfers to `check_lease` and returns at algorithm.lua:453–455 when batch>1 ⇒ that branch is unreachable (dead code)
- **Other references**: bench/quota.sh:94 (comment text only); README.md:26/205, docs/architecture.md:13/65/72 (the doc descriptions are outdated)
- **Recommendation**: **delete** the entire store.lua file + the algorithm.lua:10 require + the :480–484 dead code block + the compose `KONG_NGINX_HTTP_LUA_SHARED_DICT: "kong_rl 32m"` injection, and update README/architecture in sync
- **Deletion impact**: no runtime impact (Phase 7's measured EVAL=0 proves the current path has zero EVAL/shared behavior); after a docker-compose restart the shared dict no longer allocates 32m
- **Verification method**: full regression (lease-unit 25 / algorithm-lease 17+15 / config-isolation 15+14 / handler-fault 26 / quota b1+b20 / dims 8 / rules 14 / the four 6.5 scripts) + a single-round Phase 7 matrix spot check (EVALSHA==request count, EVAL=0)
- **Note**: the handler.lua:17 comment mentions store being cleaned up in Phase 8 — update that comment when deleting

### 3.2 docker-compose `KONG_NGINX_HTTP_LUA_SHARED_DICT`

- **Code location**: docker-compose.yml:33
- **Current references**: consumed only by store.lua's `ngx.shared["kong_rl"]` (3.1); zero references elsewhere in the plugin (grep for shared in handler/algorithm/lease/redis/schema finds nothing)
- **Recommendation**: delete this env injection along with 3.1 (keep the `worker_processes=2` comment)
- **Verification**: compose restart healthy + the regressions above

### 3.3 RL-DEBUG hot-path logs (7 sites, all notice-level)

- **Code locations**: algorithm.lua:289 (multi_grant), 316 (multi_reject), 354 (local_hit), 381 (lease_grant), 410 (lease_take_after_grant), 459 (redis_grant), 480 (local_fill)
- **Current references**: the Phase 6/7 **test frameworks depend on them** — matrix.sh's localHit/leaseGrant/multi columns and some 6.5/6.4 log assertions grep these markers
- **Problem**: 1 notice log + string concatenation per request (Phase 1 measured log backpressure once causing a p95 3.5s spike); production defaults should not emit hot-path debugging
- **Recommendation**: downgrade to `kong.log.debug` (only emitted at KONG_LOG_LEVEL=debug) — **retain all fields and markers**; test scripts switch to running at debug level or change their assertion scope; `redis.lua:436` NOSCRIPT warn and handler 429 notice/fault err·warn **stay untouched** (needed for troubleshooting)
- **Impact**: the log-level assumptions of matrix.sh and affected E2Es must be updated in sync (test-framework changes, executed with the batch); zero change to behavioral semantics
- **Verification**: at notice level requests emit no RL-DEBUG; at debug level fields are complete; single matrix round (KongCPU comparison) + fault regression

### 3.4 `LEASE_TTL_MS = 3600000` (algorithm.lua:21)

- **Code location/references**: single definition; the only consumption point is algorithm.lua:371 → lease.grant → GRANT_LEASE's `PEXPIRE lkey` (redis.lua:279)
- **Conclusion**: **keep the constant**. There is no duplicated configuration; making it configurable would introduce schema/validation/lifecycle issues and V1 has no such requirement (design.md freezes a note that "after Phase 5 introduces RETURN/max_lifetime, this constant is handed back to configuration management")
- **Semantic clarification (must be preserved)**: this TTL is only the expiry of the Redis **lease metadata record**, unrelated to local inventory return/auto RETURN — documentation must not describe PEXPIRE as automatic return (Deferred)

### 3.5 Other audit conclusions (items with evidence)

| Item | Evidence | Conclusion |
|---|---|---|
| Redis connection management | redis.lua:655/701 `set_keepalive(10000,100)`; dual connect paths (single rule/multi-key) | ✓ normal; no leaks (no connection pile-up during Phase 7's long benchmark) |
| EVALSHA/NOSCRIPT self-healing | only NOSCRIPT triggers LOAD + exactly one retry; timeouts do not trigger | ✓ frozen and verified |
| nil,err handling order | algorithm.lua:452 checks nil before dereferencing | ✓ (issue A of rule.md §9.1 already fixed) |
| Lua table lifecycle/memory growth | lease.lua's `leases` table retains CLOSED records, `_pools` never deleted | V1 frozen (kept for diagnostics); grows with config churn/high-cardinality dimensions — P3, handled together with Phase 5 pool reclamation |
| 429/503 distinction, Retry-After capping | handler.lua D1/D2 fully implemented | ✓ |
| Config hot reload | fingerprint isolation verified (6.3) | ✓ (old pools die naturally) |
| Test reproducibility | all scripts follow independent ns/FLUSHDB conventions; the 6.5 scripts verified reproducible multiple times in practice | ✓ |

**P0/P1: none**.

## 4. Production-readiness issue list (only items with code evidence)

| # | Issue | Code evidence | Impact | Severity | Proposed fix | Acceptance criteria |
|---|---|---|---|---|---|---|
| 1 | store.lua dead code + compose shared-dict remnant | algorithm.lua:10/483 unreachable; compose:33 | misleads readers, 32m of memory wasted | P3 | Batch A deletion (§3.1/3.2) | full regression green + EVAL=0 |
| 2 | RL-DEBUG notice hot-path logs ×7 | 7 sites in algorithm.lua | high-concurrency log CPU/IO overhead; production noise | P3 | Batch B downgrade to debug | no output at notice, complete fields at debug, regression green |
| 3 | README/architecture descriptions outdated (store.lua/shared dict/old inventory semantics) | README.md:26/205, architecture.md:13/65/72 | misleads deployment and maintenance | P3 | Batch C doc rewrite aligned to V1 | docs consistent with code/reports |
| 4 | CLOSED records and `_pools` never cleaned | lease.lua `leases`/`_pools` lifecycle | slow memory growth over long runs (high-cardinality dimensions) | P3 | **Deferred** (together with Phase 5 pool reclamation/RETURN wiring), untouched in V1 | — (listed as known limitation) |
| 5 | `LEASE_TTL_MS` hardcoded | algorithm.lua:21 | no practical impact | P3 (keep) | do not make configurable (§3.4) | — |
| 6 | Untracked `1113.json` | workspace | repo tidiness | P4 | session export; keep local, do not commit (.gitignore optional) | workspace declaration |

## 5. Phased cleanup plan (each batch an independent commit + independent rollback)

### Batch A: Legacy inventory implementation removal
- **Files to change**: delete `lib/store.lua`; `algorithm.lua` (drop the require + dead code block 480–484); `docker-compose.yml` (drop the shared-dict env); sync the wording of the `handler.lua:17` comment; the store/shared-related lines in README/architecture
- **Purpose**: eliminate the deprecated implementation and config remnants
- **Allowed scope**: only the store/shared-related lines in the files above
- **Prohibited scope**: the semantics of the three request paths, lease/redis/protocol, batch semantics, fingerprint rules, schema fields
- **Tests**: full regression (the §3.1 list) + a single matrix round (EVALSHA==request count, EVAL=0, leaseGrant ratio unchanged)
- **Acceptance**: all regressions green; `grep -r store kong/plugins` zero references; compose up/down healthy
- **Rollback**: `git revert` that commit (one commit one topic)

### Batch B: RL-DEBUG log downgrade
- **Files to change**: `lib/algorithm.lua` (7 sites notice→debug; fields and markers retained); the log levels/assertions of affected test scripts (matrix.sh `-L` default or E2E grep scope — **test-framework changes, no production semantics change**)
- **Purpose**: eliminate hot-path notice overhead while keeping debug-level diagnosability
- **Prohibited scope**: NOSCRIPT warn, 429 notice, fault err/warn, log field contents
- **Tests**: zero RL-DEBUG request logs at notice level; complete fields at debug level; handler-fault-e2e 26 + one matrix round (KongCPU comparison recorded) + full regression
- **Rollback**: revert

### Batch C: Documentation and delivery polish
- **Files to change**: README.md (rewrite architecture/deployment/config/testing/known limitations), docs/architecture.md (V1 architecture diagram: the lease model), docs/docker-mirror.md if affected
- **Purpose**: let other developers understand, deploy, test, and maintain
- **Prohibited scope**: must not claim Deferred capabilities are implemented; must not change frozen conclusions
- **Tests**: check every referenced path in the docs one by one + zero code diff
- **Rollback**: revert

### Batch D: Final verification and wrap-up
- `git diff --check`, tasks.md Phase 8 check-off (the 7.3 matrix check was already completed with 7.3), final commit `refactor: remove legacy local inventory implementation` (if A–C are batched, this is either a summary commit or absorbed by A, to be decided at review time)

## 6. Deferred items (not part of this V1 cleanup; must not be written as done)

- **Auto RETURN** (the RETURN_LEASE Lua is implemented, not wired in V1)
- **Worker takeover / lease auto-compensation / inventory replenishment**
- **idle scanner / max_lifetime** (local pool reclamation falls under their remit)
- **Redis Cluster adaptation** (per-node script caching, multi-key same slot) and its performance verification
- **Redis HA/primary-replica failover** behavior verification
- **Long-duration stability benchmark (>24h) and memory curves**
- **Prometheus metric export / tracing** (`_counters` is only an internal foundation)
- **p99 re-test in an isolated environment** (the Phase 7 NOT VERIFIED item)

## 7. Final deliverables checklist (still needed from Phase 8.2+)

| Item | Current state | To do |
|---|---|---|
| README | Outdated (store/shared/old semantics) | Batch C rewrite: features, three paths, deployment (compose/production essentials), config field table, test entry points, known-limitations referencing §6 |
| Architecture doc | architecture.md's old model | Batch C redraw: the worker local lease model, Redis responsibilities, fault semantics |
| Deployment doc | Missing production essentials | Batch C: Redis dependency/timeouts/fault_tolerant trade-offs/TTL semantics/upgrade notes (referencing Phase 6.6 §16) |
| Configuration doc | Scattered across schema | Batch C: field table + batch trade-offs (loss exposure) + limit_by cardinality risk |
| Testing doc | Scripts complete | Batch C: categorized index (unit/E2E/fault/performance) + reproducible execution scope |
| Performance report | ✓ Phase 7 | Delivered |
| Known limitations | Phase 6.6 §13–§14 | Batch C summarizes and references them in README |
| Interview walkthrough material | Phase 6.6 §17 conclusions available | Optional: a standalone walkthrough doc (decision chain + data) |

---

*This report was generated from the actual code at HEAD `bc46c8c` and a repo-wide reference analysis; zero code/config/doc changes during the audit.*
