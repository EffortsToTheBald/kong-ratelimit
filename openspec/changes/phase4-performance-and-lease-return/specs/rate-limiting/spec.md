# Spec Delta

## ADDED Requirements

### Requirement: EVALSHA script management
The plugin MUST manage the source text and SHA of the four Lua scripts (TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE) uniformly in an in-module script table, with unique stable script names and no duplicate maintenance of the same text across modules (MUST NOT); init_worker MUST NOT execute cosocket Redis IO directly, loading MUST be done via a timer or lazy loading, and a failure only warns once without affecting initialization. At runtime it MUST execute via EVALSHA; **explicit NOSCRIPT** ⇒ SCRIPT LOAD and retry exactly once; a timeout MUST NOT be treated as NOSCRIPT; other errors MUST NOT be retried indefinitely; loading and self-heal MUST NOT cause duplicate deduction. The GRANT and RETURN recovery paths MUST be verified separately.

#### Scenario: Redis unavailable during init ⇒ initialization is not blocked
- **WHEN** Redis is unavailable when the script-loading timer runs
- **THEN** the plugin completes initialization normally (warns once); the first real request triggers lazy loading; if that still fails, it follows the configured 503/degradation, with no Lua exceptions

#### Scenario: NOSCRIPT self-heal without duplicate deduction (GRANT and RETURN verified separately)
- **WHEN** after Redis `SCRIPT FLUSH`, requests on the GRANT path and the RETURN path are triggered separately
- **THEN** each auto-reloads and retries exactly once, with bucket deduction/return each happening exactly once (HGET before/after comparison)

#### Scenario: A timeout is not treated as NOSCRIPT
- **WHEN** EVALSHA times out (Redis unresponsive)
- **THEN** no SCRIPT LOAD reload is triggered; it is handled per the timeout semantics (GRANT: no retry, loss allowed; RETURN: enters the idempotent retry policy)

#### Scenario: Zero behavioral regression
- **WHEN** after switching to EVALSHA, the existing regression suite is re-run (quota batch=1, dims.sh, rules.sh)
- **THEN** all results match the existing anchors

### Requirement: Performance baseline and comparative measurement
> **V1 acceptance scope (2026-11-13 final ruling)**: three points = **M0 (reusing the Phase 1 baseline) / batch=1 / batch=10**; Workers 1/multi, rate low/medium/high; recording RPS, p50/p95/p99, Redis QPS; the focus is verifying that batch=10 reduces Redis request count while keeping rate limiting correct; same basis as Phase 1. **Deferred/Future**: batch=50/100, the full EVAL/EVALSHA comparison, the RETURN switch, automatic RETURN performance, the failure recovery matrix, lifecycle statistics—these MUST NOT be listed as V1 acceptance conditions. The Phase 1 Legacy data is only a historical baseline. Fabricating data is not allowed (MUST NOT); unexecuted items MUST be marked NOT RUN with the reason. (The original full matrix serves as the reference for restoring Phase 7; the EVALSHA feature is already delivered, only the full performance comparison matrix is deferred.)
Performance data MUST come from real runs; V1 MUST execute the three points above on the same test basis as Phase 1; unexecuted tests MUST be marked NOT RUN with the reason.

#### Scenario: M0 reuses the Phase 1 Legacy baseline
- **WHEN** the M0 point of V1 performance acceptance is executed
- **THEN** it directly references the Phase 1 Legacy baseline data already on disk (not re-executed), and the report marks the data source and basis; it MUST NOT be passed off as measured data of the new Lease implementation

#### Scenario: batch=1 and batch=10 measured on the same basis
- **WHEN** the measurement is executed per tasks.md Phase 7.2: batch=1 (strict Redis path) and batch=10 (Worker-local Lease path), each covering Worker 1/multi × rate low/medium/high, both using the same test environment and test basis
- **THEN** RPS, p50/p95/p99, and Redis QPS are recorded; verify that batch=10 reduces the Redis request count while rate-limiting correctness is preserved; unexecuted tests MUST be marked NOT RUN with the reason, and data MUST NOT be fabricated

### Requirement: Lease mode applicability boundary
> **V1 scope ruling (2026-11-13)**: V1 **does not implement automatic return**—exhaustion means CLOSED: removed from the consumable set and retained in the local table only for diagnostics (not deleted), lost on crash (the conservative direction, never re-granted); the RETURN_LEASE Lua protocol is implemented (50 items in the Phase 3 matrix) but **V1 does not wire in automatic RETURN calls**; idle/max_lifetime return is a production TODO.
The Worker-local Lease mechanism applies ONLY to **single-rule batch>1** (>1 after auto resolution); its idle-return behavior (a V1 note) is a Phase 5 restoration item and is not implemented in V1. batch=1 keeps the existing strict Redis path; multi-rule keeps the existing atomic multi-key flow and MUST NOT use local Leases; the Lease mechanism MUST be a no-op for batch=1 and multi-rule (zero Lease creation, zero RETURN, zero related error logs).

#### Scenario: batch=1 strict path has zero change
- **WHEN** the Phase 1 baseline (450 requests, exactly 100 admitted) and the dual failure paths are re-run with batch=1
- **THEN** the results match the existing anchors and there are no Lease records in Redis

#### Scenario: Multi-rule path has zero change
- **WHEN** all scenarios of rules.sh are re-run
- **THEN** all green and no Lease records in Redis; the multi-rule "one empty, one non-empty ⇒ 429 and both buckets unchanged" semantics is unchanged

#### Scenario: Single-rule batch>1 uses a Lease
- **WHEN** requests are issued with batch=20
- **THEN** the first request creates a Lease via GRANT (a lease record visible in Redis, status OPEN); subsequent requests consume via local TAKE, with no per-request Redis operations

### Requirement: Lease ownership and local state machine
> **V1 scope ruling (2026-11-13)**: the state machine is simplified to a one-way **ACTIVE → CLOSED** (remaining=0 ⇒ CLOSED: removed from the consumable set and retained in the local table only for diagnostics; no CLOSING return state, no Redis RETURN call—the RETURN_LEASE Lua protocol is implemented and retained but not wired into V1; Redis Lease records are not cleaned up and no inventory compensation is executed). The close/RETURN-related MUSTs are to be specified when Phase 5 is restored.
Each Lease MUST belong only to the Worker that created it (a Worker-level Lua table, not shared, no shared.DICT aggregated inventory); the state machine MUST be one-way and CLOSED re-entry into consumption is forbidden; TAKE MUST complete lookup/check/decrement within a synchronous segment containing no yield points; remaining MUST NOT go negative, with no compensation path. (When Phase 5 is restored: closing goes local first—set CLOSING, remove, snapshot requested, zero out—before calling Redis RETURN.) Consumption after close is not allowed (MUST NOT).

#### Scenario: TAKE has no yield and no negative inventory
- **WHEN** a request TAKEs on an active Lease
- **THEN** the check and the decrement complete in the same non-yield segment (code review + protocol-level test assertions), remaining is monotonically non-negative, and there is no compensation path

#### Scenario: Close precedes RETURN and removal is immediate (**DEFERRED / Phase 5**—V1 has no timer-driven close and RETURN, not a V1 acceptance condition)
- **WHEN** a timer decides to close a Lease and a yield happens during RETURN
- **THEN** that Lease was already set to CLOSING and removed from the ACTIVE set before the yield; no request during that window can consume it via TAKE, and independent Leases created by later GRANTs are unaffected

#### Scenario: Not consumable after close
- **WHEN** a request TAKEs after the Lease has entered CLOSED
- **THEN** that Lease has been removed from the consumable set and does not participate in TAKE, but remains in the local table only for diagnostics (not deleted, cannot revive, MUST NOT re-enter ACTIVE); the request consumes other ACTIVE Leases under the same pool_key, and when no ACTIVE Lease is available it enters a new GRANT flow

#### Scenario: Multi-Worker isolation
- **WHEN** Worker A and Worker B each create Leases A/B via GRANT
- **THEN** A can only consume and close A, B can only consume and close B; A's crash does not affect B's Leases or consumption

### Requirement: Lease lifecycle management
> **Status: DEFERRED / OUT OF SCOPE FOR V1 (2026-11-13 ruling)**—this item is the complete specification for when Phase 5 restores automatic return; not implemented in V1 and must not be treated as a delivered capability. The V1 lifecycle = ACTIVE until inventory exhaustion; on exhaustion it is no longer consumable and the leftover tokens are lost with the Worker (the conservative direction).
Each Lease MUST have two close conditions: idle (monotonic clock interval ≥ `lease_return_idle`, default 10s, 0–3600, 0=disabled) or age (≥ `lease_max_lifetime`, default 300s, 10–3600, forced rotation); `max_lifetime ≥ idle` is enforced by configuration validation. Local intervals MUST use a truly monotonic clock (CLOCK_MONOTONIC semantics, no imitations allowed); the clock MUST be injectable. Each Worker MUST run a 1s scanner + re-entry protection. Thresholds MUST be snapshotted at creation time.

#### Scenario: Idle timeout close
- **WHEN** the Lease's last_used_at is ≥ lease_return_idle ago
- **THEN** the scanner closes the Lease (CLOSING → RETURN → CLOSED)

#### Scenario: Max lifetime forced close
- **WHEN** the Lease keeps being consumed by requests, the idle condition is never met, and age reaches lease_max_lifetime
- **THEN** the Lease is force-closed and the remaining inventory returned; it cannot be consumed after close; subsequent requests create a new Lease

#### Scenario: Max lifetime still applies when idle=0
- **WHEN** lease_return_idle=0 and the Lease reaches lease_max_lifetime
- **THEN** it is still force-closed and returned (max lifetime cannot be disabled)

#### Scenario: Configuration snapshot isolation
- **WHEN** lease_return_idle/lease_max_lifetime are modified at runtime
- **THEN** existing Leases close per the thresholds snapshotted at creation, new Leases use the new thresholds, and there are no retroactive modifications

### Requirement: GRANT atomicity and timeout semantics
The Lease grant MUST be completed atomically by a single Redis Lua script: parameter validation → bucket read/refill (elapsed = max(0, now−ts); rate/capacity use a unified source with TOKEN_BUCKET/RETURN_LEASE, and MUST NOT differ across scripts) → grant decision and deduction (partial grants allowed; tokens<1 ⇒ granted=0 and **no Lease created**) → creation of the unique Lease record (status=OPEN) → setting the TTL ⇒ returning granted. It MUST NOT deduct the bucket first and have the client create the record separately; on failure of a critical step it MUST NOT return success. lease_id MUST be globally unique; if a record with the same ID already exists ⇒ reject (LEASE_EXISTS) and enter the failure branch, without retrying with a different ID (MUST NOT). When the GRANT result is ambiguous (timeout), it MUST NOT be automatically retried (both same ID and new ID are forbidden), and inventory loss is allowed; in the scenario where Redis already executed, both the record and the deduction have taken effect.

#### Scenario: GRANT creates atomically
- **WHEN** a GRANT is issued when no local inventory is available
- **THEN** bucket refill/deduction and Lease record creation (OPEN) complete within the single script; if the script fails, there is no successful return with "bucket deducted but no Lease record"

#### Scenario: Insufficient tokens
- **WHEN** tokens < 1 in the bucket
- **THEN** granted=0, no Lease record created, and the request returns 429 per the existing semantics

#### Scenario: GRANT timeout is never blindly retried
- **WHEN** the GRANT times out (Redis may have already executed: bucket deducted, Lease created)
- **THEN** the client does not retry (neither same ID nor new ID is allowed); that batch of inventory is booked as a loss; the request is handled by the failure branch

#### Scenario: Lease ID conflict rejection
- **WHEN** the lease_id submitted by GRANT already has a record in Redis
- **THEN** the explicit error LEASE_EXISTS is returned, with no overwrite, no idempotent replay, entering the failure branch

### Requirement: RETURN write order and idempotent commit point
> **V1 boundary (2026-11-13)**: the Lua protocol is implemented (verified by 50 items in the Phase 3 matrix); the V1 request path does not wire in automatic RETURN calls (requested/applied/discarded are not consumed in the V1 request path); the protocol is used directly upon restoration.
RETURN MUST be completed by a single Redis Lua script, and the write order MUST be **committing the RETURNED idempotency marker (including return_requested) first, then writing the complete bucket state in one HSET** (refill→+requested→capped at capacity; requested=0 still completes the marker)—the marker is the idempotent commit point: if the bucket update fails after the marker ⇒ a retry gets ALREADY_RETURNED and does not re-add to the bucket (loss allowed); "add to bucket first, mark later" is forbidden (MUST). It returns requested/applied/discarded (applied+discarded=requested, 0≤applied≤requested); capacity-capped discards are booked as losses and MUST NOT revert to OPEN due to the cap; the number of bucket increments for the same lease_id MUST be ≤1.

#### Scenario: Marker written, bucket update fails ⇒ retry does not double-return
- **WHEN** the script throws after writing the RETURNED marker but before the bucket HSET, and the client retries with the original arguments
- **THEN** ALREADY_RETURNED is returned and the bucket is not incremented; the shortfall is booked as a loss (double return is not allowed, MUST NOT)

#### Scenario: Normal return triple and capacity cap
- **WHEN** the bucket has room / partial room / is full at return time
- **THEN** applied+discarded=requested and 0≤applied≤requested; fully capped ⇒ applied=0, discarded=requested, booked as a loss

#### Scenario: requested=0 still completes the state transition
- **WHEN** the Lease closes after its inventory is fully consumed (requested=0)
- **THEN** the bucket is not modified, and the status still goes OPEN→RETURNED (ledger closure)

### Requirement: RETURN validation and error code semantics
> **V1 boundary**: the Lua protocol is implemented (verified in Phase 3); the V1 request path does not wire in automatic RETURN calls.
All RETURN validations MUST precede any write and fail with zero writes: record does not exist ⇒ LEASE_NOT_FOUND (no bucket addition allowed, MUST NOT); status=RETURNED ⇒ same requested yields ALREADY_RETURNED, different yields RETURN_CONFLICT; not OPEN ⇒ INVALID_LEASE_STATE; pool_key mismatch ⇒ POOL_MISMATCH; requested > granted ⇒ INVALID_REQUESTED; bucket does not exist ⇒ BUCKET_NOT_FOUND (no compensation via a new bucket, MUST NOT); illegal parameters ⇒ INVALID_ARGUMENT. Ambiguous result ⇒ retry only with the original lease_id + original requested, a limited number of times (≤3 total; explicit errors are not retried), with loss allowed once the cap is reached; retrying with a different ID is forbidden, and treating LEASE_NOT_FOUND as success is forbidden.

#### Scenario: Same ID, different requested ⇒ RETURN_CONFLICT
- **WHEN** after the Lease is RETURNED (return_requested=5), it is submitted again with requested=3
- **THEN** RETURN_CONFLICT is returned and the bucket is not incremented

#### Scenario: Bucket does not exist ⇒ BUCKET_NOT_FOUND
- **WHEN** the target bucket has expired / does not exist at RETURN time
- **THEN** BUCKET_NOT_FOUND is returned with zero writes; that batch of inventory is booked as a loss

#### Scenario: Limited retries and error classification
- **WHEN** after a RETURN timeout, retries with the original ID + original requested (up to 2 more times, 3 attempts total) remain ambiguous; or an explicit parameter/state error is received
- **THEN** explicit errors are not retried; at the cap, retries stop and loss is allowed; under any circumstances the bucket inventory is incremented at most once (≤1)

#### Scenario: Normal return triple
- **WHEN** the Lease closes with requested=remaining inventory and RETURNs (bucket has room / partial room / is full)
- **THEN** it returns requested/applied/discarded with 0 ≤ applied ≤ requested and discarded = requested − applied; the Lease status goes OPEN→RETURNED; capacity-capped discards are booked as losses

#### Scenario: Idempotent retry does not double-add tokens
- **WHEN** the first RETURN already executed successfully in Redis but the response was lost, and the client retries with the same lease_id + same requested
- **THEN** Redis returns ALREADY_RETURNED, the bucket is not incremented, and there is no double return

#### Scenario: Concurrent RETURN idempotency
- **WHEN** two RETURNs (same Lease) arrive concurrently
- **THEN** Redis serializes them: the first completes OPEN→RETURNED, the second gets ALREADY_RETURNED, and the bucket is incremented exactly once

#### Scenario: Expired Lease record rejects return
- **WHEN** a RETURN is submitted after the Lease record has expired (TTL death)
- **THEN** LEASE_NOT_FOUND is returned and the bucket is not incremented (no speculative inventory return allowed); that batch of inventory is booked as a loss

#### Scenario: Same ID, different requested ⇒ RETURN_CONFLICT
- **WHEN** after the Lease is RETURNED (return_requested=5), it is submitted again with requested=3
- **THEN** RETURN_CONFLICT is returned and the bucket is not incremented (a different requested MUST NOT be treated as the same retry)

#### Scenario: Bucket does not exist ⇒ BUCKET_NOT_FOUND
- **WHEN** the target bucket has expired / does not exist at RETURN time
- **THEN** BUCKET_NOT_FOUND is returned with zero writes; compensating the old Lease via a new bucket is forbidden; that batch of inventory is booked as a loss

#### Scenario: RETURNED marker succeeds but the bucket update fails ⇒ retry does not double-return
- **WHEN** the script throws after writing the RETURNED marker but before the bucket HSET, and the client retries with the original arguments
- **THEN** ALREADY_RETURNED is returned and the bucket is not incremented; that batch's shortfall is booked as a loss (double return is not allowed, MUST NOT)

#### Scenario: Return with requested=0
- **WHEN** the Lease closes after its inventory is fully consumed (requested=0)
- **THEN** the bucket is not modified and the Lease status still transitions OPEN→RETURNED (ledger closure)

#### Scenario: Limited idempotent retries
- **WHEN** after a RETURN timeout, retries with the original ID + original requested hit the attempt/time cap while remaining ambiguous
- **THEN** retries stop, inventory is lost, and the log records outcome=uncertain; explicit parameter/state errors never enter the retry loop

### Requirement: Configuration-change isolation and ledger boundary
> **V1 ledger basis (2026-11-13 ruling)**: V1 has no automatic RETURN; the ledger is unified as—**during normal operation** `granted = consumed + outstanding` (outstanding = Worker-local granted inventory not yet consumed, i.e., Σremaining); **after a Worker crash** `granted = consumed + lost` (lost = granted inventory remaining that can no longer be consumed due to the crash). V1 does not promise precise real-time lost auditing (returned_applied is not part of the V1 normal ledger).
`pool_key` MUST include the configuration version (reusing the existing policy fingerprint): a configuration change produces a new pool_key, and the new configuration MUST NOT consume old Leases; a configuration change MUST NOT retroactively affect existing Leases. An explicit Lease set MUST satisfy the V1 ledger basis and `consumed ≤ granted`; production does not promise a precise ledger. A Worker crash MUST only lose inventory and MUST NOT double-grant or compensate across Workers.

#### Scenario: Configuration-change isolation (V1: pool_key isolation)
- **WHEN** changing the limit produces a new policy fingerprint and a new pool_key, while unconsumed Leases still exist under the old pool_key
- **THEN** old Leases remain bound to the original pool_key; the new configuration uses the new pool_key and MUST NOT consume old Leases; the remaining of old Leases MUST NOT be merged into new Leases; the new configuration MUST NOT reuse the old configuration's local inventory; V1 does not execute idle/max threshold closing or automatic RETURN (the lifecycle threshold snapshot behavior is Phase 5 deferred and not a V1 acceptance requirement)

#### Scenario: Normal-operation ledger closure (V1: outstanding basis)
- **WHEN** a failure-free deterministic sequence: GRANT 100, consume 80, the Worker runs normally, and the Lease is still ACTIVE (not exhausted)
- **THEN** granted = 100, consumed = 80, outstanding = 20 (outstanding = Σ local remaining), lost = 0; satisfying `granted = consumed + outstanding` (the same inventory MUST NOT be counted in both outstanding and lost)

#### Scenario: Worker crash ledger (V1: lost basis)
- **WHEN** the Worker crashes while the Lease is ACTIVE (outstanding = 20)
- **THEN** the remaining 20 units of granted inventory can no longer be consumed ⇒ lost = 20; satisfying `granted = consumed + lost`; no automatic return is executed, no cross-Worker takeover, no over-admission, and other Workers are unaffected; lost is a ledger concept—V1 does NOT require (MUST NOT) precise real-time lost auditing, persisted auditing, or cross-Worker recovery
