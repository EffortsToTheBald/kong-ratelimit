# Design

## Context

**Verified implementation facts** (2026-11-12, measured in container):

1. Kong 3.6 has no plugin-level exit_worker hook; timer behavior during exit is unverified (Branch to be determined by measurement in 1.3).
2. cosockets cannot run directly during the init_worker phase; they can inside timer callbacks (measured: `SCRIPT LOAD` inside a resty timer returns a SHA).
3. `resty.redis` supports `script` (LOAD) / `eval` / `evalsha`.
4. Redis Lua runtime errors **do not roll back already-executed write operations**; NOSCRIPT is a pre-execution error with zero script writes.
5. `redis-cli CLIENT PAUSE <ms>` can make clients time out while Redis subsequently completes execution—used to deterministically construct "executed but response lost".
6. Each Kong Worker runs an independent Lua VM: module-level Lua tables are naturally isolated per Worker; OpenResty coroutine switches happen only at yield points (cosocket/ngx.sleep etc.)—**a Lua synchronous segment containing no yields is invisible to interleaving by other coroutines**, which is the boundary of local state-machine atomicity.
7. Existing assets: the policy fingerprint (`p=`, Phase 1) is already a reliable configuration version identifier and can directly serve as the configuration version component of pool_key; the Redis TIME + `elapsed = max(0, now−ts)` clock-rollback protection (review finding P0-4) is already implemented in the bucket script.
8. Fact-checking to-dos (1.2): whether OpenResty has a native monotonic clock API (if not, use a "soft-monotonic" wrapper, see D5); availability of `CLIENT PAUSE` in this environment.

**Architecture pivot (the fundamental change of this phase's design)**: abandon the lock-free arithmetic protocol of "aggregated inventory counter + snapshot-based fixed-quota subtraction + borrow fix" in favor of an ownership model that **creates an independent Lease per GRANT**. Pivot rationale (carrying over the review conclusions):

- The aggregated balance cannot distinguish inventory ownership: increments before and after a snapshot, interleavings of multiple drains, and interactions between borrow fix and TAKE can only be inferred arithmetically; multi-step INCR is not an atomic transaction; "fill surviving after the snapshot" covers only part of the window (the pause window between the fill metadata write and the inventory write was declared as a glitch).
- A single balance cannot express the independent lifecycle of each GRANT (independent idle/forced rotation/independent return).
- Under the ownership model, the correctness boundary shrinks to two **provable** points: the "synchronous segment without yields" inside the Worker (guaranteed by coroutine scheduling) and Redis "single-script atomicity" (guaranteed by Redis serialization). No compensating arithmetic is needed anymore.

**Core principle of this phase**: correctness first, not maximizing recovery rate; rather lose unused local inventory than allow double consumption or double return; guarantees that cannot be proven must be marked as limitations.

## Goals / Non-Goals

**Goals:**

- EVALSHA (four scripts unified into one script table; NOSCRIPT self-heal; timeout≠NOSCRIPT; no duplicate deduction)—**done (Phase 2)**.
- Independent Lease mechanism for single-rule batch>1: GRANT atomically creates the Lease, Worker-local TAKE, inventory exhausted ⇒ CLOSED/removed from the consumable set with the local diagnostic record retained; **V1 has no close-and-return flow** (the Redis idempotent RETURN Lua is implemented but not wired into V1).
- Performance comparison (V1 compressed: M0 reuses Phase 1 + batch=1 strict mode + batch=10 Lease mode), real data.
- Zero change to batch=1 and multi-rule semantics; zero Redis operations on the hot path (TAKE).

**Non-Goals (V1, see Future Considerations and the V1 scope ruling section for details):**

- **Automatic lifecycle management (deferred entirely in V1)**: CLOCK_MONOTONIC+FFI, idle scanner, automatic RETURN calls, max_lifetime closing, scanner re-entry protection, lifecycle configuration (lease_return_idle/lease_max_lifetime do not enter the V1 schema).
- Redis Cluster multi-slot atomicity; multi-rule local inventory; cross-Worker Lease sharing; Worker failure takeover; precise production consumption ledger; reliable SIGTERM return guarantee; cross-instance local inventory sharing; inventory compensation after Lease expiry; complex distributed inventory coordination protocols; batch auto-tuning; complex prefetching strategies; soak test; production monitoring/auditing.

## Decisions

### D1. EVALSHA script management (four scripts unified into one script table)

**Structure**: an in-module Lua table `{ name → { src, sha, loaded } }` (token_bucket / grant_multi / grant_lease / return_lease), independent of the Lease state machine implementation, not framework-ized.

- Loading: init_worker `ngx.timer.at(0, load_scripts)`; on failure warn once, not fatal; lazy loading converges with the NOSCRIPT path.
- Execution: EVALSHA; **explicit NOSCRIPT** (error message contains NOSCRIPT) → SCRIPT LOAD → retry exactly once; a timeout does **not** enter this path; consecutive failures → explicit error → the existing failure branch.
- No-duplicate-deduction argument: NOSCRIPT is a pre-execution error with zero script writes, so retry is safe; the GRANT path and the RETURN path are recovered and tested separately (spec scenarios).
- GRANT/RETURN timeout semantics differ: GRANT timeout = ambiguous result = no retry (D4); RETURN timeout = entry point for idempotent retry (D6)—decided by the caller's semantics; the script management layer only passes through results and error categories (noscript/explicit error/uncertain).

**Test cases**: resty unit tests (NOSCRIPT injection → retry count =1; timeout does not trigger LOAD; LOAD returns malformed → explicit error); E2E (after SCRIPT FLUSH, go through the GRANT and RETURN paths separately, comparing HGET before/after for no duplicate deduction); commandstats (eval=0/evalsha=N).

### D2. Lease model and ownership (Worker-level Lua table; TAKE has no yield)

**Data structure** (Worker-level module table, naturally isolated per Worker):

```lua
-- inside lease.lua (one copy per Worker)
pools = { [pool_key] = { leases = { lease_obj, ... } } }
lease_obj = {
  lease_id, pool_key,
  granted,          -- amount actually granted by Redis (GRANT return value)
  remaining,        -- local remainder (≥0, synchronously decremented by take)
  consumed,         -- local cumulative consumption (for ledger observation)
  created_at,       -- grant moment (for diagnostics)
  state,            -- V1: "ACTIVE" | "CLOSED" (no CLOSING return state)
}
-- removed in V1 (re-introduced when Phase 5 is restored): last_used_at / idle_threshold / max_lifetime
```

- **TAKE (non-yield synchronous segment)**: iterate the ACTIVE Leases of that pool, take the first with `remaining > 0`: `remaining −= 1; consumed += 1`; none available ⇒ NEED_GRANT. (V1 has no last_used_at—no consumer of idle decisions.) The check and the decrement are in the same Lua segment with no cosocket/ngx.sleep/timer waits in between ⇒ coroutine scheduling cannot interleave (Fact 6)—this is the complete proof of atomicity; no compensation path is needed.
- **Ownership**: a Lease object exists only in the table of the Worker that created it; structurally invisible to other Workers (Invariants 2 and 10).
- **Conflict with existing code (called out first; adjustment suggestions in the file change list)**: `store.lua` (ngx.shared.DICT aggregated inventory) is the only implementation of the old batch>1 path and is **deprecated and deleted entirely** under the new model (no two L2 implementations kept, no backward compatibility); `handler.lua`'s shared-dict degradation warning (Phase 2 D5) is deleted along with it; docker-compose's `KONG_NGINX_HTTP_LUA_SHARED_DICT` injection is no longer used by this plugin (whether to keep it is left to the implementation group to confirm—recommend deletion with docs updated in sync).
- **TAKE order**: take the first Lease with stock remaining in insertion order (no correctness difference versus LRU/FIFO; V1 has no max_lifetime rotation; an exhausted Lease stays in the local table as a diagnostic record after being CLOSED, no longer participating in consumption).
- **Multiple concurrent Leases constraint (V1)**: multiple Leases may coexist for the same pool_key (each with its own lease_id); after a successful GRANT, register the new Lease **in a local code segment that does not yield** (appended to the leases list, **never overwriting an existing Lease**); TAKE iterates consumable Leases and picks one with remainder; check and decrement are in the same non-yield segment. The Redis GRANT has already atomically deducted the global bucket ⇒ multiple coexisting Leases cannot double-allocate global inventory.

**Test cases**: resty protocol-level unit tests (driving lease.lua directly): TAKE decrements/zeroed cannot take again/multiple Leases coexist/exhausted is not consumable/CLOSED cannot revive/negative inventory impossible (structural assertions). **V1 has no injected-clock premise** (no idle/max lifetime decisions—injected clocks belong to Phase 5, deferred).

### D3. Lease state machine and close flow (local first, Redis later)



**V1 exhaustion handling (local first, same non-yield segment)**:

```
1. remaining == 0 (TAKE can no longer take from this Lease) ⇒ state = "CLOSED", removed from the ACTIVE set
2. CLOSED cannot revive and cannot be consumed again; it remains in the local table only as a diagnostic record (no deletion, no return, no Redis record cleanup)
3. Subsequent requests cannot TAKE ⇒ NEED_GRANT ⇒ apply for a new Lease (new lease_id)
```

**Deferred Reference (historical/deferred design, not the basis of the V1 implementation)**—when Phase 5 restores automatic return, implement the full flow below:

```
ACTIVE ──(idle threshold / max_lifetime expiry)──► CLOSING ──(RETURN completed)──► CLOSED
```

**Close flow (steps 1–6 MUST be in the same non-yield segment)**:

```
1. state == "ACTIVE"? No ⇒ skip
2. idle reached (idle_threshold > 0 and idle ≥ idle_threshold) or age ≥ max_lifetime?
   No ⇒ skip (when idle_threshold=0, skip the idle condition; max_lifetime is always checked)
3. state = "CLOSING"
4. Remove this Lease from pools[pool_key].leases
5. requested = remaining; remaining = 0
6. (end of synchronous segment; yields allowed from here on)
7. Redis RETURN(lease_id, pool_key, requested)—limited idempotent retries (D6)
8. Clean up by result: success/ALREADY_RETURNED ⇒ CLOSED; LEASE_NOT_FOUND/retry cap reached ⇒ CLOSED + lost bookkeeping
```

- After steps 3–5, any concurrent request's TAKE cannot see the Lease (already removed)—the proof of **Invariant 4** is the coroutine model itself: no yield in the segment ⇒ no interleaving.
- After step 6, the Lease has left the consumption path, so the RETURN yield does not affect any request; a new GRANT during this window creates an independent Lease B, fully isolated from A (Invariant 10: different Lease objects, different Redis keys).
- State machine transitions are one-way; CLOSING/CLOSED cannot be consumed or revived (Invariants 3 and 4).

**Test cases**: resty deterministic unit tests (injected clock + direct driving)—scenarios A/B/C (15.5): TAKE before close/close before TAKE/new GRANT and new Lease consumption during the RETURN yield; non-yield assertion for close-flow steps 1–6 (code review + tests with injectable yield probes).

### D4. GRANT_LEASE Lua (bucket deduction and Lease creation atomic in the same script)

**refill persistence semantics (first-group review ruling of Phase 3, cross-script comparison)**: TOKEN_BUCKET **unconditionally writes back** refill state (HSET+PEXPIRE even when granted=0); GRANT_MULTI does not write when the multi-key all-or-nothing semantics are not met (structural difference, not inconsistency); GRANT_LEASE is single-key and isomorphic to TOKEN_BUCKET ⇒ **the insufficient branch likewise writes back tokens/ts after refill and updates the bucket TTL**; RETURN_LEASE skips the bucket update when requested=0 (as specified by Spec; ledger closure is carried by the RETURNED marker). The wait contract is unified: consistent with TOKEN_BUCKET, computed from **post-deduction** tokens (wait>0 on partial grant). Bucket state numeric validity: tokens∈[0,capacity], ts≥0, finite numbers, granted a positive integer—illegal values return an explicit error code, MUST NOT be silently corrected, and leave data unchanged (implemented in GRANT_LEASE/RETURN_LEASE; TOKEN_BUCKET/GRANT_MULTI are historically accepted paths, differences recorded, not refactored). **TTL parameter validity (review finding P1-2, second round)**: lease_ttl_ms and bucket_ttl_ms share the unified rule = finite number + positive integer + ≥1 and <2^53 (`is_valid_ttl`)—guards against inf passing the floor comparison (inf==inf is always true), 1e20 precision loss (floor becomes unreliable beyond 2^53), and extremely large millisecond values; both TTLs in GRANT_LEASE and the one in RETURN_LEASE are all validated before any write; illegal ⇒ INVALID_ARGUMENT with zero writes (no intermediate states like "bucket deducted but Lease not created" or "marked RETURNED then failed").

```
KEYS[1] = bucket key      KEYS[2] = kong:rl:lease:{lease_id}
-- Note: {lease_id} is placeholder syntax, not a Redis hash tag—the actual key = kong:rl:lease:<lease_id> (no braces,
--     consistent with the bare-run matrix). Slot consistency between the Lease key and the bucket key under Cluster deployment is deferred (see Future Considerations 1).
ARGV = [batch, lease_ttl_ms, lease_id, pool_key] (rate/burst are derived from bucket state + TIME, same as existing scripts)
-- lease_ttl_ms semantics (V1 ruling): the caller passes a **fixed constant** (value determined at Phase 4 implementation; used only for Lease metadata expiry cleanup,
--     does not mean automatic inventory return, does not affect bucket tokens/refill or Worker-local TAKE/consumption, and has no implicit compensation/re-authorization).
--     The historical formula max_lifetime+3×timeout+60s is Phase 5 deferred design (the original GRANT_LEASE Lua implementation is retained untouched).

Phase 0 parameter validation (zero writes): batch a positive integer; lease_ttl ≥ 1; lease_id/pool_key non-empty
Phase 1 read-only state validation: EXISTS(KEYS[2]) ⇒ error LEASE_EXISTS (no overwrite)
        bucket key type ∈ {none, hash}; when hash, tokens/ts are valid numbers
Phase 2 write:
  refill (Redis TIME; elapsed = max(0, now−ts); burst cap; ts does not go backward)
  granted = min(floor(tokens), batch) (tokens < 1 ⇒ granted = 0)
  granted > 0 ⇒ tokens −= granted; HSET bucket + PEXPIRE bucket
               HSET lease:{id} (pool_key, granted, status=OPEN, created_at=Redis TIME)
               PEXPIRE lease:{id} lease_ttl_ms
  return { granted, tokens, wait } (granted=0 ⇒ no Lease created)
```

- granted ∈ [0, batch]; partial grants allowed (consistent with the existing "partial claim" semantics); granted=0 creates no record (no inventory, no Lease).
- **Bucket parameter unification (responding to the "source of rate/capacity" requirement)**: the existing bucket stores only tokens/ts (last_refill_time); rate/capacity are passed in via ARGV—TOKEN_BUCKET/GRANT_MULTI already follow this scheme, and GRANT_LEASE/RETURN_LEASE **must reuse the same ARGV scheme** (passed in by the caller, derived from conf); rate must not be derived from tokens alone, nor capacity from timestamps alone. Same pool_key ⇒ same policy fingerprint ⇒ same limit/window/burst ⇒ the rate/capacity received by the three scripts are **provably consistent** (RETURN is initiated by the creating Worker with pool_key validation as a backstop).
- **Bucket semantics unification**: refill formula `elapsed = max(0, now−ts)`, full bucket for a new bucket (tokens=burst), ts does not go backward, float tostring, TTL=2×window—isomorphic across the four scripts TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE, verified by independent script files + identical test vectors (each writing its own refill is forbidden).
- **Execution-phase residue (declared truthfully)**: after validation, the write sequence is theoretically interruptible and non-transactional—bucket deducted first, record created later; an interruption ⇒ bucket deducted but no record ⇒ inventory loss (under-admission direction) + alert; zero writes during the execution phase MUST NOT be claimed.
- lease_id generation (client side): `<hostname>:<worker_id>:<in-process monotonic counter>:<random hex>`; conflicts are backstopped by the script's EXISTS check (LEASE_EXISTS → failure branch; the generation rule makes the probability ≈0).
- GRANT timeout: ambiguous result ⇒ the client does not retry (both same ID and new ID are forbidden); if Redis already executed ⇒ the Lease exists but the Worker has no local copy ⇒ that Lease's inventory dies with the record's TTL (loss direction); the request takes the failure branch.

**Test cases**: dual-source diff empty (redis/grant_lease.lua vs embedded); resty bare-run matrix—full bucket/partial grant/insufficient/LEASE_EXISTS/wrong type/illegal parameters (zero-write assertions); two Workers concurrently GRANT with correct global quota; `CLIENT PAUSE` constructs a GRANT timeout (Redis already executed) ⇒ the client does not retry, the record and deduction have taken effect, and inventory loss is booked.

### D5. Time source (true monotonic clock, mandatory)

- **Local idle/age MUST use Linux `clock_gettime(CLOCK_MONOTONIC)` semantics**: called via LuaJIT FFI (given that resty.core has FFI enabled), wrapped as the injectable interface `now()` (which also serves as the clock control point for deterministic tests). It MUST NOT be claimed monotonic via ngx.now()/ngx.update_time() or a max wrapper (forward wall-clock jumps cannot be captured by max), and local intervals must not be computed with Redis TIME.
- **Phase 0 verification items**: FFI availability, `clock_gettime` ABI/return values/error handling, the `CLOCK_MONOTONIC` constant, deployment environment (in-container) compatibility. **Verification failure ⇒ stop all Lease lifecycle implementation and report the environment limitation** (the spec allows pausing; quietly substituting a non-qualifying clock is not allowed).
- The Redis bucket refill keeps using Redis TIME + `elapsed = max(0, now−ts)` (review finding P0-4 semantics retained, unrelated to the local clock).

**Test cases**: injected-clock unit tests covering—normal monotonic advance/wall-clock rollback/wall-clock forward jump/monotonic advance with unchanged wall clock/idle trigger/max_lifetime trigger.

### D6. RETURN_LEASE Lua (idempotent commit point first + error codes)

**Write order (a substantive correction relative to the previous design version)**: **write the RETURNED idempotency marker (including return_requested) first, then write the complete bucket state in a single HSET**. Rationale: Redis Lua runtime errors do not roll back—under "add to bucket first, mark later", an interruption + retry would **add to the bucket again** (double return, violating the top invariant); with the marker written first, an interruption ⇒ retry gets ALREADY_RETURNED and does not re-add; the shortfall is booked as a loss (under-admission direction). **Step 12 (the marker) is the idempotent commit point**: after it, any failure must not allow another return.

**Execution flow (validation before any write; all within a single script, serialized by Redis with no interleaving)**:

```
 1. Parameter validation (requested a non-negative integer <2^53, lease_id/pool_key non-empty, correct argument count) ⇒ INVALID_ARGUMENT
 2. Read the Lease record: does not exist ⇒ LEASE_NOT_FOUND (no bucket addition allowed)
 3. status = RETURNED ⇒ same requested ⇒ ALREADY_RETURNED; different ⇒ RETURN_CONFLICT (compare against return_requested)
 4. status ≠ OPEN ⇒ INVALID_LEASE_STATE
 5. pool_key mismatch ⇒ POOL_MISMATCH
 6. requested > granted ⇒ INVALID_REQUESTED
 7. Read the bucket: does not exist ⇒ BUCKET_NOT_FOUND (new-bucket compensation forbidden); illegal type/field ⇒ INVALID_ARGUMENT
 8. [Idempotent commit point] HSET lease status=RETURNED, return_requested=requested
 9. requested > 0 ⇒ compute post-refill bucket state → +requested → capped at capacity
    ⇒ one HSET writes the complete bucket state (tokens/ts; multi-field split updates forbidden)
10. Maintain the bucket TTL per the existing policy (consistent with the grant side)
11. Return { requested, applied, discarded } (applied+discarded=requested; requested=0 ⇒ applied=discarded=0)
```

- **Error code table**: SUCCESS / ALREADY_RETURNED / RETURN_CONFLICT / LEASE_NOT_FOUND / INVALID_LEASE_STATE / POOL_MISMATCH / INVALID_REQUESTED / BUCKET_NOT_FOUND / INVALID_ARGUMENT (naming may be unified per project style; semantics unchanged).
- **Residual write semantics (declared truthfully)**: a bucket-update failure after the commit point ⇒ RETURNED already decided, bucket not added ⇒ loss (under-admission); zero writes during the execution phase MUST NOT be claimed. Validation failures ⇒ zero writes.
- **requested=0**: skips the bucket update but still completes OPEN→RETURNED (ledger closure).
- **Bucket does not exist**: new-bucket compensation forbidden / inference from old policy parameters forbidden ⇒ loss.

**RETURN retry policy**: retry only ambiguous results (timeout/connection interruption) with the **original lease_id + original requested**, at most 3 attempts total (including the first) with a short sleep between attempts; explicit errors are not retried; ALREADY_RETURNED = a successful terminal state; cap reached ⇒ CLOSED + lost.

**Test cases**: bare-run matrix—normal/duplicate with same arguments (ALREADY_RETURNED, bucket not incremented)/same ID different arguments (RETURN_CONFLICT)/two concurrent RETURNs (bucket incremented exactly once)/requested=0/>granted/expired Lease (LEASE_NOT_FOUND)/**expired bucket (BUCKET_NOT_FOUND, zero writes)**/post-marker bucket failure injection (retry does not double-return); E2E `CLIENT PAUSE` timeout ⇒ idempotent retry and the bucket is incremented exactly once.

### D7. Configuration change and pool_key (fingerprint reuse; lifecycle parameters snapshotted into the Lease)

- `pool_key` = the existing bucket key (containing the `p=<policy fingerprint>` configuration version component + dimension values)—the fingerprint already covers limit/window/burst/limit_by/header_name, i.e., all quota-semantics configuration ⇒ a configuration change ⇒ a new pool_key ⇒ new Leases, naturally isolated (invariant: new configuration does not consume old Leases).
- `lease_return_idle` / `lease_max_lifetime` are **not in the fingerprint and do not enter the V1 schema** (lifecycle parameters deferred in V1): introduced only when Phase 5 is restored, at which point isolation is achieved via snapshots at Lease creation (no first-writer-wins/conflict alerts needed—ownership is already isolated per Worker).
- batch change: batch is not in the fingerprint; after a batch change, new GRANTs grant with the new batch while existing Leases are consumed/returned per their granted—the ledger is unaffected.

**Test cases**: configuration-change E2E (changing limit ⇒ new pool_key, new Leases, old/new Leases isolated). **The idle/max threshold change part ("old Leases close per old thresholds / new Leases use new values") belongs to Phase 5, deferred**—V1 does not introduce the lease_return_idle/lease_max_lifetime configuration, and it is not a V1 acceptance requirement.

### D8. Metrics and ledger observation

- **Worker-local counters + structured logging** (notice): the V1 mandatory set = lease_granted/consumed/active/closed/local_remaining; **return_requested/return_applied/return_discarded/return_failed/return_duplicate are defined for future extension—the V1 request path does not consume these metrics (no automatic RETURN), and they MUST NOT be listed as V1-mandatory** (enabled when automatic return is restored). The TAKE hot path has zero Redis operations (counters are local variables). Prometheus exposure is left to Phase 5 (deferred); this phase provides test and report evidence via logs + the resty-callable `lease.stats()`.
- **Deterministic ledger (V1 basis)**: under normal operation `granted = consumed + outstanding` (outstanding = Σ local remaining); after a Worker crash `granted = consumed + lost` (lost = granted inventory that can no longer be consumed). `returned_applied` is not part of the V1 normal ledger (the RETURN Lua is implemented but not wired into V1; re-introduced when automatic return is restored). The bucket's current tokens **cannot** be treated directly as the ledger because of refill/cap—tests only tally explicit Lease sets.

**Test cases (V1 basis)**: deterministic sequence ledger closure (grant 100/consume 80 ⇒ outstanding 20, identity granted = consumed + outstanding); Worker crash basis (granted = consumed + lost). **Capacity-capped discard/RETURN (return 20) scenarios belong to Phase 5, deferred** (V1 has no automatic RETURN; returned_applied is not part of the V1 normal ledger).

## Correctness invariants (same as the Spec, with proof boundaries item by item)

| # | Invariant | Proof boundary |
|---|---|---|
| 1 | Global grants never exceed quota | GRANT Lua deducts the bucket atomically in a single script (Redis serialization) |
| 2 | A Lease has a unique owner | Structural isolation of Worker-level tables (independent Lua VM per Worker) |
| 3 | Local inventory never goes negative | TAKE non-yield synchronous segment + no compensation path (code-review assertion) |
| 4 | Not consumable after close | V1: exhaustion ⇒ CLOSED/removed (local first); (when Phase 5 is restored: CLOSING+removal completed before any RETURN yield) |
| 5 | Each Lease succeeds in RETURNing at most once | Redis OPEN→RETURNED atomic transition in a single script; duplicates ⇒ ALREADY_RETURNED |
| 6 | 0 ≤ requested ≤ granted | At close, requested=remaining ∈ [0, granted] (remaining is monotonically non-negative, granted is the initial value); the Redis side validates and rejects out-of-range values |
| 7 | Ambiguous results never mint new quota | GRANT does not retry; RETURN retries idempotently only with the original ID + original requested |
| 8 | A Worker crash only loses inventory | No cross-Worker compensation path (structurally nonexistent); OPEN records die via TTL |
| 9 | Lease records do not expire early | V1: fixed lease_ttl constant (value fixed in Phase 4); (when Phase 5 is restored: formula covering max_lifetime + retry window + margin, D6) |
| 10 | Different Leases are mutually isolated | Independent objects + independent Redis keys; TAKE/close/RETURN only touch themselves |

## Risks / Trade-offs

- **Lower inventory recovery rate**: under the ownership model, losses from Worker crash/GRANT timeout/record expiry are uncompensatable (a design choice: correctness first). Loss upper bound = the sum of remaining across a single Worker's unclosed Leases ≤ per-pool batch × number of active Leases; quantified in the report.
- **One Lease per GRANT ⇒ Redis record count = GRANT count**: at a high GRANT frequency (1 per batch requests), record count = request volume/batch; TTL-bounded ⇒ bounded stock (≈ number of active Leases + records within the RETURNED protection window); HGETALL is no longer needed (direct lookup by lease_id). The report assesses the actual scale.
- **RETURN retries introduce a new failure surface**: limited retries (≤2) only for uncertain errors; retry-storm risk is bounded by the cap.
- **Soft-monotonic clock**: rollback protection is imperfect (a long pause spanning a rollback can still be misjudged)—it affects only idle/age decision deviations (close timing), not the ledger; replaced by the native monotonic API if one exists (1.2 verification).
- **Execution-phase residual writes**: after validation, the GRANT/RETURN Lua write sequences are theoretically interruptible and non-transactional ⇒ both directions are under-admission (bucket deducted, no record / bucket added, status not transitioned) + alert; zero writes must not be claimed.
- **Regression surface of deleting store.lua**: the batch>1 path is rewritten as a whole—Phase 1/2 anchors (batch baseline, dual failure paths) must be re-tested with the new implementation and the report must note the reasons for anchor changes.
- **Matrix noise** (container environment): marked truthfully; no multi-round medians.
- **The EVALSHA comparison may show limited improvement**: the goal is to confirm effectiveness; record truthfully.

## Future Considerations / Deferred Items

### 1. Redis Cluster support
Background: the GRANT/RETURN Lua operates on both the bucket key and the lease key, possibly across slots. Limitation: standalone only this phase; docs do not claim Cluster support. Risk: misconfiguration ⇒ multi-key EVAL errors (fail-closed, no wrong-ledger unavailability). Direction: fold the lease key into the bucket's hash tag / an independent registry service.

### 2. Precise production consumption ledger
Background: after a Worker crash, local remaining is unrecoverable; GRANT/RETURN timeouts are indistinguishable. Limitation: exact only within deterministic test windows; conservative upper bound in production. Risk: promising exactness while the implementation falls short ⇒ damaged trust. Direction: persist consumption counts (RETURN carries the consumed increment into the record), node-level reconciliation.

### 3. Worker failure takeover
Background: a Worker crash ⇒ its Lease inventory is lost. Limitation: no cross-Worker compensation/takeover/leader election. Risk: losses accumulate with crash frequency (under-admission). Direction: Lease record heartbeats + a takeover protocol (separate design).

### 4. Reliable SIGTERM return
Background: timer behavior during exit is unverified. Limitation: best-effort exiting polling only. Risk: restart loss ≤ the sum of this Worker's remaining. Direction: signal handlers/external drain hooks; let data speak first.

### 5. Multi-rule local inventory (β)
Background: multi-rule α mode costs 1 RTT per request. Limitation: not implemented this phase. Risk: none (behavior identical to Phase 3). Direction: a multi-Lease joint grant-and-return protocol (separate change).

### 6. GRANT idempotency
Background: GRANT timeouts lose inventory. Limitation: no GRANT idempotency this phase (ambiguous result, no retry). Risk: deployments with a high GRANT timeout rate have amplified inventory loss. Direction: lease_id pre-registration (SET NX) + GRANT idempotent semantics (separate change).

## Migration Plan (aligned to the implementation spec's Phases 0–8, one independent commit per phase)

0. **Phase 0 code status review** (no production code modified) → `docs/PHASE0_REVIEW.md`: existing architecture/bucket fields and parameter sources/EVAL path/multi-rule implementation/deviations from the spec/conflicts and risks; any blocking incompatibility ⇒ pause coding and report first.
1. **Phase 1 EVAL baseline**: complete the baseline tests and run them → first version of results.md (`test: add phase4 eval performance baseline`).
2. **Phase 2 EVALSHA**: unified script registration/LOAD/EVALSHA/NOSCRIPT recovery/four-script verification/regression + the second performance set (`feat: add evalsha script management`).
3. **Phase 3 Redis Lease data model**: Lease key/fields/GRANT_LEASE/RETURN_LEASE (idempotent commit point first)/TTL/validation and idempotency tests; not wired to the request path (`feat: add redis lease grant and return scripts`).
4. **Phase 4 Worker-local Lease**: Worker table/state machine/TAKE/GRANT invocation/remainder maintenance/single close flow; no scanner yet, unit tests first (`feat: add worker local lease manager`).
5. **Phase 5 Lease lifecycle**: monotonic clock/idle/max/per-Worker scanner/re-entry protection/RETURN limited retries/configuration snapshot and isolation (`feat: add lease lifecycle and idle return`).
6. **Phase 6 request-path integration**: batch=1 preserved/batch>1 wired/multi-rule preserved/failure and 429/503 behavior/configuration compatibility/end-to-end regression (`feat: integrate worker lease into rate limit path`).
7. **Phase 7 performance tests and report**: third test set/three-way comparison/inventory loss and rate-limiting error/NOT RUN markers (`test: add phase4 lease performance report`).
8. **Phase 8 cleanup**: only when all tests pass—delete the store.lua aggregated implementation/shared dict state/duplicate paths/obsolete configuration, update README (`refactor: remove legacy local inventory implementation`).
9. Rollback: revert phase-level commits; the batch=1 path is never touched, providing fallback semantics.

## Acceptance Criteria (aligned to §17's 21 items)

| # | Acceptance item | Evidence |
|---|---|---|
| 1 | EVALSHA + NOSCRIPT self-heal (GRANT/RETURN verified separately) | HGET comparison after SCRIPT FLUSH + commandstats |
| 2 | batch=1 consistent with the existing strict path | quota.sh batch=1 baseline 100/350/0 + dual failure paths |
| 3 | Single-rule batch>1 uses independent Leases | Redis lease records visible, status OPEN→RETURNED |
| 4 | A single Worker owner per Lease | Multi-Worker test (A/B mutually invisible, never managing each other) |
| 5 | TAKE never yields negative inventory | Protocol-level unit tests + structural assertions (no compensation path) |
| 6 | TAKE has no yield points | Code review + tests with injectable yield probes |
| 7 | Not consumable after close | State-machine unit tests (scenarios A/B/C) |
| 8 | Idle timeout close (**Phase 5 deferred, not V1 acceptance**) | Injected-clock unit tests + E2E |
| 9 | Max lifetime forced close (**Phase 5 deferred, not V1 acceptance**) | Injected-clock unit tests (continuously consuming Lease) + E2E |
| 10 | GRANT atomically creates the Lease record | Bare-run matrix + failures never return success with "bucket deducted, no record" |
| 11 | RETURN atomically updates bucket and status | Bare-run matrix + no OPEN intermediate-state assertion |
| 12 | Duplicate RETURN does not double-add to the bucket | Idempotency unit tests + E2E |
| 13 | RETURN timeout same-argument retry is safe | CLIENT PAUSE both branches + retry count assertion |
| 14 | Ambiguous GRANT results are never blindly retried | CLIENT PAUSE + retry count =0 assertion |
| 15 | A Worker crash only loses inventory | kill -9 deterministic ledger (granted−consumed−returned=lost) |
| 16 | TAKE/RETURN concurrency tests pass | Scenarios A/B/C deterministic tests |
| 17 | Multi-rule atomic deduction has no regression | rules.sh all green |
| 18 | New/old configuration Leases are isolated | Configuration-change E2E |
| 19 | Lease TTL coverage formula | PTTL assertions + OPEN-expired RETURN rejection test |
| 20 | Performance report uses real data | results.md + NOT RUN markers |
| 21 | Test results and an independent commit per phase | git log + each group's report section |

Acceptance discipline: stop on FAIL; either no NOT RUN or truthfully marked; anchor changes must note the reason (the batch>1 path rewrite is an expected change); reports must not claim unimplemented guarantees (precise ledger/Cluster/SIGTERM guarantee/fencing).

## Open Questions

(None blocking. 1.2 verification: whether a native monotonic API exists (replace soft-monotonic if so); 1.3 SIGTERM branch; execution confirmation of the store.lua deletion and compose shared-dict cleanup—deletion recommended, to be executed by the implementation group in Phase 4.5.)
