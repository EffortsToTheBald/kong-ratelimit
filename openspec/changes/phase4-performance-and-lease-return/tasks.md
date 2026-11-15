# Tasks

> Spec basis: `specs/rate-limiting/spec.md` (9 ADDED items); implementation basis: `design.md` (D1–D8 + the invariant table + Future Considerations) + the final implementation spec (Phases 0–8, commit conventions, prohibitions).
> **Phase number mapping (2026-11-13 ruling)**: task groups 3/4/5/6 in this file ↔ implementation spec Phases 3/4/5/6; Phase 7 (third performance group) and Phase 8 (cleanup) run as independent phases per the spec. **Lease Key = `kong:rl:lease:{lease_id}`** (following the kong:rl prefix; Cluster slot consistency is not guaranteed within this phase). **The threshold field name is uniformly `idle_threshold`**. The Phase 3 kickoff cross-check conclusions are in this round's conversation and the commit history (no blocking conflicts).
> **Execution principles**: inspect the code before modifying; Phase 0 only reviews and does not modify production code; no skipping phases, no mixing commits; stop on test failure; do not modify test expectations (unless the original test is proven wrong with an explanation); NOT RUN marked truthfully; never keep two production rate-limiting implementations; report spec/code conflicts first.

## Phase 0: Code status review (no production code modified)

- [x] 0.1 Review the existing implementation and produce `docs/PHASE0_REVIEW.md`: current architecture and key functions, bucket fields (tokens/ts) and the source of rate/capacity (ARGV), the bucket TTL policy (2×window), the EVAL call path, the multi-rule atomic implementation, the existing batch>1 inventory logic (store.lua shared dict), Worker init/exit and timer status, Redis key design, configuration schema, the deviation list versus this spec, compatibility impact, implementation risks; any blocking incompatibility ⇒ pause coding and report first; verification: the report covers the 10 items of implementation spec §14 and the facts match the code
- [x] 0.2 Produce the list of files to modify, design conflicts, and the Phase 1 execution plan; verification: see PHASE0_REVIEW.md §Deviations/§File list/§Phase 1 plan

## Phase 1: EVAL baseline (`test: add phase4 eval performance baseline`)

- [x] 1.1 Environment self-check + baseline commit (`--allow-empty` anchor if the tree is clean); verification: `docker compose ps` all running
- [x] 1.2 First-day fact checking (blocking items up front): LuaJIT FFI `clock_gettime(CLOCK_MONOTONIC)` availability (ABI/return values/error handling/container compatibility); `CLIENT PAUSE` availability; empirical verification of Worker-level module table isolation; verification: resty output archived; **monotonic-clock verification failure ⇒ stop the Phase 5 lifecycle implementation and report** (does not block Phases 1/2)
- [x] 1.3 Extend `matrix.sh` with the first group of dimensions: batch 1/10/50/100, rate low/medium/high, Workers 1/multi, single/multi-rule, Redis CPU (INFO cpu delta), Kong CPU, commandstats category columns; verification: one dry-run group passes
- [x] 1.4 Run the EVAL baseline → `bench/results.md` baseline section (raw data preserved); verification: data is real and re-runnable with the same parameters in Phases 2/7
- [x] 1.5 Commit `test: add phase4 eval performance baseline`; verification: the commit appears in git log (`8b04976`)

## Phase 2: EVALSHA (`feat: add evalsha script management`)

- [x] 2.1 Unified script registration (**implementation deviation: Phase 2 wires in only the existing two scripts TOKEN_BUCKET/GRANT_MULTI**; GRANT_LEASE/RETURN_LEASE are registered at Phase 3; lazy loading replaces the init timer—both satisfy the spec's "timer or lazy loading") + an evalsha wrapper (explicit NOSCRIPT ⇒ LOAD ⇒ retry exactly once; a timeout does not trigger LOAD) + error-category pass-through; verification: all 8 resty unit test cases green (`test/evalsha-unit.sh`, including NOSCRIPT retry count=1, timeout/disconnection not triggering LOAD, LOAD failure, lazy loading)
- [x] 2.2 E2E: after SCRIPT FLUSH (on an isolated test Redis), verify self-heal separately via the batch=1 and multi-rule paths (200 + warn logs token_bucket/grant_multi; commandstats eval no longer grows / evalsha=N) + **empirical verification of independent lazy loading per Worker** (three nodes' miss counts match the request distribution); the stop-Redis-during-init sub-item: under lazy-loading semantics, initialization itself has no Redis IO (covered by failure regression); verification: spec (EVALSHA) four scenarios
- [x] 2.3 Regression: quota.sh batch=1 (100/350/0) + dims.sh + rules.sh all green; verification: spec (EVALSHA · zero behavioral regression)
- [x] 2.4 The second performance group (same parameters as the first group, only the script invocation differs) → results.md EVALSHA comparison section; verification: no other logic changes mixed in
- [x] 2.5 Commit `feat: add evalsha script management`; verification: git log

## Phase 3: Redis Lease data model (`feat: add redis lease grant and return scripts`; not wired to the request path)

- [x] 3.1 `redis/grant_lease.lua` (standalone bare-run) and the embedded GRANT_LEASE dual-source: KEYS[1]=bucket key, KEYS[2]=kong:rl:lease:{lease_id}, ARGV=[batch,lease_ttl_ms,lease_id,pool_key,rate,capacity,bucket_ttl_ms] (rate/capacity/bucket_ttl follow the same ARGV scheme as the other scripts); three phases (parameter validation ⇒ EXISTS ⇒ LEASE_EXISTS; bucket type/field validation ⇒ refill(elapsed=max(0,now−ts))/granted=min(batch,floor(tokens))/tokens<1 ⇒ granted=0, no record created/deduct bucket + HSET lease(status=OPEN,granted,pool_key,created_at=Redis TIME) + PEXPIRE); verification: dual-source diff empty + resty bare-run matrix (full bucket/partial grant/insufficient granted=0, no record/LEASE_EXISTS/illegal parameters or bucket fields ⇒ zero writes)
- [x] 3.2 `redis/return_lease.lua` (standalone bare-run) and the embedded RETURN_LEASE dual-source: **idempotent commit point first**—KEYS[1]=kong:rl:lease:{lease_id}, KEYS[2]=bucket key, ARGV=[requested,pool_key,bucket_ttl_ms,rate,capacity]; validation (requested a non-negative integer <2^53 ⇒ INVALID_ARGUMENT; does not exist ⇒ LEASE_NOT_FOUND; RETURNED ⇒ same requested ALREADY_RETURNED / different RETURN_CONFLICT; not OPEN / POOL_MISMATCH / requested>granted rejected; bucket does not exist ⇒ BUCKET_NOT_FOUND; illegal bucket fields rejected—all zero writes) ⇒ commit point HSET lease(status=RETURNED,return_requested) ⇒ requested>0 ⇒ refill→+requested→capped at capacity ⇒ one HSET writes the complete bucket state + TTL ⇒ return {requested,applied,discarded}; verification: dual-source diff empty + resty bare-run matrix (§5.9 twelve items fully covered: normal/duplicate same-arguments bucket not incremented/different arguments RETURN_CONFLICT/two concurrent RETURNs bucket incremented exactly once/requested=0 transitions status/requested=granted/requested>granted rejected/expired Lease LEASE_NOT_FOUND/expired bucket BUCKET_NOT_FOUND zero writes/illegal parameters zero writes)
- [x] 3.3 Post-marker bucket-update failure test: inject a failure after the RETURNED commit but before the bucket HSET ⇒ retry gets ALREADY_RETURNED, the bucket is not incremented, and the shortfall is booked as a loss; verification: spec (idempotent commit point scenario)
- [x] 3.4 Lease TTL: the GRANT-side formula `lease_ttl = lease_max_lifetime + 3×redis_timeout_s + 60` (uniformly, never shortened; RETURNED does not shorten the TTL); verification: PTTL assertion == formula value. **V1 note (2026-11-13)**: this formula is the Phase 3 historical verification basis (the Lua implementation is retained); the V1 call semantics change to a fixed lease_ttl constant (see design D4/Phase 4 scope), and V1 does not depend on the lease_max_lifetime configuration
- [x] 3.5 refill semantics consistency test vectors: the four scripts (TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE) run the same vectors with the same bucket state + same TIME input ⇒ identical refill results; verification: the test vector table archived
- [x] 3.6 Group test report + commit `feat: add redis lease grant and return scripts`; verification: git log

## Phase 4: Worker-local Lease (`feat: add worker local lease manager`; no scanner, unit tests first)

> **V1 scope (2026-11-13 ruling)**: the state machine is simplified to **ACTIVE→CLOSED** (inventory exhausted ⇒ CLOSED/local deletion, no CLOSING return state, no Redis RETURN call); no lifecycle thresholds/clock/scanner; a Worker crash ⇒ the remaining inventory is lost (no recovery, no compensation).

- [x] 4.1 Add `lib/lease.lua` (Worker-level module table): the pools/leases structure, the lease object (lease_id/pool_key/granted/remaining/consumed/status/created_at—**V1 has no idle_threshold/max_lifetime/last_used_at**; the invariants remaining+consumed=granted and 0≤remaining≤granted); verification: resty unit tests (structural assertions + remaining/consumed conservation)
- [x] 4.2 TAKE (non-yield synchronous segment: look up ACTIVE→remaining>0→remaining−−→consumed++→ALLOW; otherwise ⇒ NEED_GRANT; no Redis access, no waiting, no compensation path; **V1 does not update last_used_at**—no consumer of idle decisions); verification: resty unit tests (decrement/zeroed cannot take again/multiple Leases taken in insertion order/remaining≥0 structural assertion) + a yield probe asserting no yield within the segment
- [x] 4.3 Exhaustion handling (V1 simplified): remaining=0 ⇒ mark the Lease CLOSED/remove it from the ACTIVE set (local first, same non-yield segment); CLOSED cannot revive and cannot be consumed again; **no RETURN call, no snapshot step**; verification: resty unit tests (exhausted Lease not selected by TAKE/CLOSED cannot revive/repeated marking is skipped)
- [x] 4.4 GRANT invocation wiring (lease_id generation: hostname+worker+counter+random; GRANT_LEASE invocation and result classification: success creates the local Lease / granted=0 / LEASE_EXISTS and other explicit errors ⇒ failure branch / **uncertain ⇒ no retry, loss allowed**; local `remaining+consumed=granted` maintenance); **multiple coexisting Leases**: multiple Leases under the same pool_key each with independent lease_id, registered after a successful GRANT in a non-yield segment (append, never overwrite), TAKE iterating and picking one with remainder; the Redis side has already atomically deducted the bucket ⇒ coexistence causes no duplicate allocation; verification: resty unit tests (GRANT success/insufficient/conflict/uncertain four classifications + multiple coexisting Leases) + structural assertions that **remaining>granted and negative inventory never occur**
- [x] 4.5 Multi-Worker isolation: A/B's Leases are mutually invisible and never managed by the other; A's crash (table discarded) does not affect B and does not re-grant; verification: resty dual-VM/separate-process verification + spec (ownership scenario)
- [x] 4.6 Group test report + commit `feat: add worker local lease manager`; verification: git log

## Phase 5: Lease lifecycle — **DEFERRED / OUT OF SCOPE FOR V1**

> **2026-11-13 ruling**: this phase is **not implemented in V1** as a whole. V1 adopts the conservative "inventory exhausted means loss" model (Phase 4.3) and does not implement automatic return. The tasks below are retained verbatim as the specification for restoring Phase 5 and **must not** be quietly merged into Phase 4 or Phase 6.

- [ ] 5.1 【DEFERRED】Land the monotonic clock (FFI CLOCK_MONOTONIC; verification failure ⇒ stop this Phase and report)
- [ ] 5.2 【DEFERRED】Per-Worker scanner + sweeping re-entry protection + failure isolation + deferred records
- [ ] 5.3 【DEFERRED】idle/max close triggers (thresholds taken from the Lease creation snapshot; idle=0 means only max applies)
- [ ] 5.4 【DEFERRED】Land the RETURN limited retry policy (uncertain only, original ID + original requested, ≤3 times)
- [ ] 5.5 【DEFERRED】Configuration snapshot and isolation E2E (the POOL_MISMATCH rejection path E2E)
- [ ] 5.6 【DEFERRED】Group test report + commit `feat: add lease lifecycle and idle return`

## Phase 6: Request-path integration (`feat: integrate worker lease into rate limit path`; the core V1 phase)

> **V1 scope**: wire in only batch>1's Lease consumption and application; **no scanner startup, no SIGTERM return, no close/RETURN interleaving** (inventory exhausted ⇒ a new Lease).

- [x] 6.1 `algorithm.lua` wiring: single-rule batch>1 ⇒ TAKE → NEED_GRANT ⇒ GRANT_LEASE → create the local Lease/consume 1; granted=0 ⇒ 429; **the batch=1 and multi-rule paths are untouched line by line**; verification: resty unit tests + the three-mode behavior matrix
- [x] 6.2 `handler.lua`: cross-check the failure branch wiring (Redis unavailable ⇒ the existing 503/degradation semantics are not changed by the Lease; the Lease must not bypass fail-closed; 429/503 semantics are not conflated); **V1 has no scanner startup**; verification: startup logs + failure injection
- [x] 6.3 Configuration isolation cross-check: the pool_key fingerprint covers limit/window/burst/limit_by/header_name ⇒ different configurations do not share local inventory; report any unclear points before acting; verification: configuration-change E2E (old/new Leases isolated)
- [x] 6.4 Full regression: quota.sh (batch=1 baseline 100/350/0 + batch=20 range—note the reason for anchor changes) + dims.sh + rules.sh all green; the dual failure paths; script-cache-loss self-heal; verification: spec (the three applicability-boundary scenarios + EVALSHA zero regression)
- [x] 6.5 Concurrency and exception E2E (V1 basis): multiple Workers concurrently TAKE/GRANT with correct global quota (no over-admission); local concurrent TAKE does not double-consume; inventory exhaustion ⇒ the new Lease flow works correctly; kill -9 ⇒ loss verification (granted−consumed=lost, no over-admission, no re-grant); Redis timeouts do not re-apply; verification: spec (ownership/ledger scenarios)
- [x] 6.6 Group test report + commit `feat: integrate worker lease into rate limit path`; verification: git log

## Phase 7: Core correctness and performance verification (`test: add phase4 lease performance report`; the V1 compressed version)

- [x] 7.1 The 11 correctness tests: ① multi-Worker concurrent application does not over-admit ② local concurrent TAKE does not double-consume ③ remaining≥0 ④ the re-application flow after exhaustion ⑤ kill -9 losses are not re-granted ⑥ batch=1 has no Lease records ⑦ multi-rule has no Lease records ⑧ multi-rule all-or-nothing ⑨ Fail-closed ⑩ 429+Retry-After ⑪ quota/dims/rules regression; verification: E2E assertions item by item
- [x] 7.2 The three performance points: M0 (reusing Phase 1 data) + batch=1 + batch=10 (Worker 1/multi × rate low/medium/high); collect RPS/p50/p95/p99/Redis QPS; focus on verifying whether batch=10 significantly reduces the Redis request count while keeping rate limiting correct; verification: same basis as Phase 1
- [x] 7.3 Phase 3 matrix evidence cross-check: confirm that the 50 items of `test/lease-redis-matrix.sh` correspond to the current final code version (if necessary, run smoke only: GRANT normal/RETURN idempotent/TTL validation spot checks); verification: the cross-check record
- [x] 7.4 Report format: number/purpose/environment/configuration/parameters/actual quantities/duration/RPS/p50/p95/p99/Redis QPS/exceptions/conclusion; unexecuted items NOT RUN; raw data committed; verification: the format conforms
- [x] 7.5 Commit `test: add phase4 lease performance report`; verification: git log

## Phase 8: Cleanup and final delivery (`refactor: remove legacy local inventory implementation`; only when all tests pass)

- [ ] 8.1 Delete `lib/store.lua` and all references, compose's `KONG_NGINX_HTTP_LUA_SHARED_DICT` and the related docs sections, and duplicate/unreachable code; verification: grep shows no residue + startup normal + the full regression still all green
- [ ] 8.2 Final delivery documents: architecture diagram, request-processing flow diagram, Lease grant and local consumption flow diagrams, README (Lease mode and error code semantics), **production TODOs** (Cluster/Worker takeover/reliable SIGTERM return/idle automatic return/CLOCK_MONOTONIC lifecycle/precise ledger/multi-rule Lease/batch tuning/prefetch strategy/soak/monitoring audit/automatic reclamation—all marked "not implemented, deferred"); verification: docs match the implementation and deferred vs. delivered items are not conflated
- [ ] 8.3 Final code review + commit `refactor: remove legacy local inventory implementation`; verification: git log


- After all Phases are complete and manual acceptance passes, run `openspec archive phase4-performance-and-lease-return` (the 9 ADDED items are appended into the main spec).
- Deferred inputs: GRANT idempotency, Redis Cluster, a precise production ledger, Worker takeover, reliable SIGTERM return, multi-rule β, the Lease cleanup index.
