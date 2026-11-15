# Proposal

## V1 Scope Ruling (2026-11-13)

**Cancel automatic lifecycle management and converge on a V1 that conforms to the take-home assignment**: the V1 request path does **not wire in automatic RETURN calls** (the RETURN_LEASE Lua protocol is implemented and retained, to be used directly on recovery); **Phase 5 lifecycle (CLOCK_MONOTONIC/scanner/idle/max_lifetime) is deferred as a whole**; the state machine is simplified to **ACTIVE→CLOSED** (exhaustion means loss, the conservative direction). Security semantics are not weakened (GRANT timeout no-retry / TAKE with no yield / fail-closed / multi-rule atomicity all retained). Where the Why/What sections below mention automatic return and lifecycle, this section prevails.

## Why

After Phase 3 was archived, the correctness baseline (Phase 1), dimensions and semantics (Phase 2), and multi-rule joint decision (Phase 3) were all closed out. Two clearly documented shortcomings remain on the way to "Ready for Production":

1. **Performance and script execution efficiency**: every EVAL uploads the full script text; the performance ⟨TODO⟩ in design.md §8 has no supporting data.
2. **Inventory lifecycle**: in the single-rule batch>1 mode, node restart/shutdown loses local inventory (in the under-admission direction), and the "aggregated inventory counter + snapshot/borrow-fix" protocol cannot reliably distinguish inventory ownership—multi-step INCR is a non-atomic transaction, increments before and after a snapshot are inseparable, and borrow-fix interacts with TAKE compensation.

This phase refactors the local inventory with an **ownership model**: the Redis global token bucket is the single source of authority; each GRANT atomically deducts the bucket and creates an **independent Lease record** (unique lease_id, status=OPEN/RETURNED) within the same Lua script; Workers exclusively own their own Lease via a Worker-level Lua table and consume it locally (TAKE does not access Redis, has no yield points, and never yields negative inventory); a Lease has dual close conditions of idle timeout and maximum lifetime (monotonic clock, configuration snapshot at creation time); Redis RETURN achieves **idempotency** through the OPEN→RETURNED atomic state transition (same lease_id + same requested is retry-safe; ALREADY_RETURNED does not re-add to the bucket). The correctness boundary shrinks to two provable points: the non-yield synchronous segment within the Worker (coroutine scheduling) and Redis single-script atomicity—no compensating arithmetic is relied upon anymore.

## What Changes

- **EVALSHA**: four scripts unified into one script table (TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE); timer-based delayed loading + lazy loading; NOSCRIPT → LOAD → retry exactly once is specified; a timeout MUST NOT be treated as NOSCRIPT; the GRANT and RETURN self-heal paths are verified separately.
- **Redis Lease data model**: `kong:rl:lease:{lease_id}` independent key (status OPEN/RETURNED, granted, pool_key, created_at); the GRANT Lua atomically completes refill/bucket deduction/record creation (partial grants allowed, no record created when tokens<1, same-ID conflict rejected); the RETURN Lua is three-phase (parameter validation/read-only validation/write) and idempotent, returning requested/applied/discarded (capacity-capped discards are counted as losses); the Lease TTL covers max_lifetime + the RETURN retry window + margin.
- **Worker-local Lease**: `lib/lease.lua` (Worker-level table)—take (non-yield synchronous segment), state machine ACTIVE→CLOSING→CLOSED (one-way), close flow goes local first (yield for RETURN is allowed only after removal); a 1s scanner per Worker + re-entry protection; monotonic clock (soft-monotonic wrapper + first-day verification of the native API).
- **Lifecycle**: `lease_return_idle` (default 10s, 0–3600, 0=disable idle trigger) + `lease_max_lifetime` (default 300s, 10–3600, forced rotation, cannot be disabled); both are written into the Lease as snapshots at creation time; configuration changes are not retroactive.
- **Timeout semantics**: ambiguous GRANT result ⇒ no retry, loss allowed; ambiguous RETURN result ⇒ limited idempotent retries with the same ID + same requested only (≤2 times), loss allowed once the cap is reached.
- **Performance matrix**: EVAL baseline first + EVALSHA re-measurement; batch 1/10/50/100 × rate × Worker count × single/multi-rule × RETURN on/off × Redis failure recovery; real data, NOT RUN marked truthfully.
- **Existing rate-limiting semantics preserved**: the batch=1 strict path and the multi-rule atomic path are untouched line by line; the Lease mechanism is a no-op for them.

## Capabilities

### Modified Capabilities

- `rate-limiting`: 8 new ADDED requirements (EVALSHA script management, performance baseline measurement, Lease applicability boundary, Lease ownership and local state machine, Lease lifecycle management, GRANT atomicity and timeout semantics, RETURN atomic idempotent return, configuration-change isolation and ledger boundary). The existing 24 requirements are unchanged.

## Impact

- **Code**: `lib/lease.lua` (new), `lib/redis.lua` (script table + EVALSHA + two new scripts), `lib/algorithm.lua` (batch>1 rewiring), `handler.lua` (scanner + failure wiring), `schema.lua` (two lifecycle configs); **`lib/store.lua` is deprecated and deleted entirely** (no two L2 implementations kept), plus cleanup of the shared-dict injection in compose and related docs; `redis/grant_lease.lua`, `redis/return_lease.lua` (new standalone scripts, dual-source sync)
- **Tests**: resty protocol-level deterministic unit tests (injected clock/borrow scenarios are handled by the unit test system), `bench/lease.sh` (new E2E), `bench/matrix.sh` extension, existing regressions (quota/dims/rules)
- **Docs**: README, docs/design.md (§2/§4 rewritten to the Lease architecture), docs/architecture.md, rule.md; report `reports/phase-4-performance-and-lease-return.md`
- **Behavioral impact**: the batch>1 path is rewritten as a whole (changes in Redis command count anchors must be explained in the report); batch=1/multi-rule has zero change
- **Explicitly not doing** (Deferred): Redis Cluster, multi-rule local inventory, cross-Worker Lease sharing/takeover, precise production ledger, reliable SIGTERM return, cross-instance inventory sharing, Lease expiry compensation, GRANT idempotency, complex distributed coordination protocols
