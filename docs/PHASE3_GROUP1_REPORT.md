# Phase 3 Group 1 (Redis Lease Data Model) Implementation Report

> Corresponds to implementation spec Phase 3 (tasks group 3); authorized scope: GRANT_LEASE/RETURN_LEASE dual sources + registration + bare-run matrix + TTL + refill vectors + idempotency fault injection. **Request path not wired.**

## 1. Modified Files

| File | Action |
|---|---|
| `redis/grant_lease.lua` | added (standalone bare-run script, with usage comments) |
| `redis/return_lease.lua` | added (standalone bare-run script, with the write-order hard-rule comment) |
| `lib/redis.lua` | registered GRANT_LEASE/RETURN_LEASE into the unified script manager (embedded dual-source src; **call wrapper functions deferred to Phase 4**) |
| `test/lease-redis-matrix.sh` | added (27-assertion bare-run matrix) |
| `test/make_inject_variant.py` | added (test variant generator for post-commit-point failure injection; **production scripts untouched**) |
| `openspec/.../{proposal,design,tasks}.md` | three ruling items synchronized in place (lease key/idle_threshold/phase mapping) |

## 2. Core Implementation

- **GRANT_LEASE** (KEYS[1]=bucket, KEYS[2]=`kong:rl:lease:{lease_id}`; ARGV=[batch,lease_ttl_ms,lease_id,pool_key,rate,capacity,bucket_ttl_ms]): three stages (argument validation, zero writes → EXISTS ⇒ LEASE_EXISTS / bucket type and field validation → refill(elapsed=max(0,now−ts)) → granted=min(batch,floor(tokens)) → tokens<1 ⇒ granted=0, **no record, no bucket debit** → bucket debit + HSET lease(status=OPEN,granted,pool_key,created_at=Redis TIME) + PEXPIRE×2).
- **RETURN_LEASE** (KEYS[1]=lease, KEYS[2]=bucket; ARGV=[requested,pool_key,bucket_ttl_ms,rate,capacity]): stage 0 arguments (requested a non-negative integer <2^53, decimal 1.5 rejected) → stage 1 read-only (LEASE_NOT_FOUND/ALREADY_RETURNED vs RETURN_CONFLICT (reads return_requested for comparison)/INVALID_LEASE_STATE/POOL_MISMATCH/INVALID_REQUESTED/BUCKET_NOT_FOUND/invalid bucket fields — all zero writes) → stage 2 writes: **[idempotent commit point] HSET lease(status=RETURNED,return_requested=requested) first** → requested>0 ⇒ refill→+requested→capacity cap ⇒ **one HSET writes the complete bucket state**+TTL → returns {requested,applied,discarded}; requested=0 skips the bucket update but still completes the state transition; **RETURN does not reset the Lease TTL** (RETURNED is retained until the original TTL = the idempotency protection window).
- **Error classification up front**: all validation precedes any write (Redis Lua runtime errors do not roll back); the nine error codes match the Spec.
- **Key ruling landed**: `kong:rl:lease:{lease_id}`; **Cluster slot consistency is not guaranteed within this phase's scope** (recorded).

## 3. Test Commands and Results

```bash
./test/lease-redis-matrix.sh        # 27-assertion bare-run matrix (real Redis)
./test/evalsha-unit.sh              # Phase 2 regression (8/8)
./test/lease-redis-matrix.sh dual-source diff  # sed-extract embedded vs standalone file
```

| Test | Type | Result |
|---|---|---|
| GRANT: normal grant (granted=5/bucket 95/OPEN/fields) | real Redis | PASS |
| GRANT: partial grant floor(2.5)=2 | real Redis | PASS |
| GRANT: tokens<1 ⇒ granted=0, no record, bucket unchanged | real Redis | PASS |
| GRANT: LEASE_EXISTS (same ID) | real Redis | PASS |
| GRANT: invalid arguments (batch=0/1.5, rate=−1) zero writes | real Redis | PASS |
| GRANT: invalid bucket field (tokens=abc) zero writes | real Redis | PASS |
| GRANT: Lease TTL PTTL ∈ [55000,60000] (60000 passed in) | real Redis | PASS |
| RETURN: normal return (applied=5, bucket 95→100, RETURNED, rr=5) | real Redis | PASS |
| RETURN: idempotent with same arguments (bucket unchanged) | real Redis | PASS |
| RETURN: different arguments RETURN_CONFLICT | real Redis | PASS |
| RETURN: requested=0 state transition (bucket unchanged) | real Redis | PASS |
| RETURN: requested>granted zero writes | real Redis | PASS |
| RETURN: POOL_MISMATCH zero writes | real Redis | PASS |
| RETURN: Lease expired ⇒ LEASE_NOT_FOUND | real Redis | PASS |
| RETURN: Bucket absent ⇒ BUCKET_NOT_FOUND, bucket not created | real Redis | PASS |
| RETURN: requested=1.5 decimal zero writes | real Redis | PASS |
| RETURN: two concurrent RETURNs (one SUCCESS one ALREADY_RETURNED, bucket incremented once) | real Redis | PASS |
| Injection: failure after the commit point (RETURNED fixed, bucket not incremented) | real Redis (test variant) | PASS |
| Injection: same-arguments retry ALREADY_RETURNED, bucket not incremented | real Redis | PASS |
| refill vectors: four scripts same state same vectors | real Redis | PASS |
| refill normalization consistency (deviation across four scripts <3s) | real Redis | PASS |
| Dual-source diff ×4 (TOKEN_BUCKET/GRANT_MULTI/GRANT_LEASE/RETURN_LEASE) | static | PASS |
| Phase 2 regression: evalsha unit 8/8, quota/dims/rules (not re-run; this group did not wire the request path, and adding Lua scripts changes no existing calls) | — | NOT RUN (mandatory re-run after Phase 4 integration) |

**Summary: PASS=27 FAIL=0** (`test/lease-redis-matrix.sh` rc=0).

## 4. Key Test Evidence

1. **Idempotent commit point order**: injected variant (after the commit point, `return redis.error_reply("INJECTED_FAILURE")`) ⇒ Lease status=RETURNED fixed, bucket tokens unchanged; production script retried with the same arguments ⇒ ALREADY_RETURNED, bucket not incremented — **empirical proof of the fail-safe behavior of "mark first, then bucket"**.
2. **Concurrent single increment**: two concurrent redis-cli RETURNs ⇒ one SUCCESS(applied=5) one ALREADY_RETURNED, bucket 95→100 exactly once.
3. **TTL boundary**: mexp (TTL=100ms) expiry ⇒ LEASE_NOT_FOUND zero writes; normal Lease PTTL ∈ [55000,60000].

## 5. Findings of This Group During Implementation (defects in the test scripts themselves, not implementation defects)

| # | Finding | Disposition |
|---|---|---|
| 1 | Each case's lease key in the bare-run matrix must be **complete** (`kong:rl:lease:mX`) — early calls passed bare IDs (m1/m2/...) causing cross-case LEASE_EXISTS contamination | fixed (all calls pass complete keys) |
| 2 | `fresh` was not parameterized (deleted only m1) ⇒ no key isolation across cases | fixed (fresh <lease_key>) |
| 3 | Non-TTL-case Lease TTL=5000ms **really expires** under host-environment jitter (4-5s, Phase 1 finding 3) ⇒ false LEASE_NOT_FOUND | fixed (non-expiry cases TTL=60000; mexp keeps 100ms) |
| 4 | bash pitfalls: `cat|head`/`local a=$1 b=${a}`/pipefail+SIGPIPE | fixed (awk-internal exit / split assignment) |
| 5 | refill vector assertion formula did not subtract granted ±1, tolerance excluded the docker exec interval | fixed (vector expectation 109/111/109/109 + normalization consistency assertion) |
| 6 | `docker cp` does not accept compose service names (requires full container names); `dexec $RC` double exec | fixed |

## 6. Unresolved Issues

1. The **call wrapper** for GRANT_LEASE/RETURN_LEASE in `lib/redis.lua` (conf→ARGV assembly, error classification) deferred to Phase 4 (not implemented per authorization).
2. Lifecycle parameters (lease_return_idle/lease_max_lifetime) not yet added to the schema (Phase 5).
3. Monotonic clock verification (a mandatory Phase 5 precondition) not executed.
4. Cluster slot consistency not promised (Deferred, recorded in Design).

## 7. Phase 3 Group 1 Review Fixes (2026-11-13, round two)

> Review (based on d30592b) conclusion: FAIL — 3 P1 items to fix.

| Issue | Fix | Tests |
|---|---|---|
| **P1-1** GRANT_LEASE wait computed before the debit (inconsistent with the interface contract) | Order corrected: granted determination → token debit → wait computed from post-debit tokens → write back → return; dual sources synchronized | Real integration: tokens=2.5/batch=5/rate=0.016 ⇒ parsed from Redis return values: granted=2, tokens≈0.5, wait≈31.25 (interval assertions, not string comparison) |
| **P1-2** TTL argument validation lacked finiteness and the 2^53 upper bound (inf/1e20 could pass the floor comparison) | `is_valid_ttl`: finite number + positive integer + ≥1 + <2^53; uniformly applied to GRANT_LEASE lease_ttl_ms/bucket_ttl_ms and RETURN_LEASE bucket_ttl_ms; all before any write | Real integration 11 assertions: 0/−1/1.5/1e20 × three arguments; invalid ⇒ INVALID_ARGUMENT zero writes (bucket not debited/Lease not created/Lease still OPEN, no "marked RETURNED then failed" intermediate state) |
| **P1-3** Matrix wait test section defects (report arguments/line continuation/R not re-executed) | Test section rewritten: independent fresh+HSET pre-seed, real partial grant, three fields sed-parsed from return values, awk numeric assertions (granted==2, tokens∈[0.5,0.5], wait∈[31.2,31.3]) | Real integration PASS (true wait=31.25) |

**Design sync**: the TTL validation rules (`is_valid_ttl` semantics) recorded in D4 (refill persistence semantics section).

### Test Results After Round-Two Fixes

- `test/lease-redis-matrix.sh`: **PASS=50 FAIL=0** (matrix 39 + wait contract 1 + invalid TTL 11 − pre-existing overlap)
- `test/evalsha-unit.sh` (Phase 2 regression): **PASS 8/8**
- Dual-source diff ×4: **PASS**
- Raw output: `bench/raw/phase1/lease-redis-matrix-final.txt` / `-full.txt`
- quota/dims/rules: **NOT RUN** (mandatory re-run in the Phase 6 integration stage)

### Round-Two Implementation-Stage Findings (test scripts themselves)

1. The 1e20 assertion initially grepped '1e+20', which does not match the Redis error string (the error string echoes the original ARGV string) — the assertion was changed to the exact original string; **the script's rejection behavior itself is correct** (real integration confirmed INVALID_ARGUMENT returned).
2. One orphan line left over from editing — cleaned up (the matrix script's final version verified by `bash -n` and a full run).

## 8. Git Commit

> Review (based on d53f3f0) conclusion: core atomicity and the idempotent commit order match the design; 4 items need fixing/supplementary verification.

| Issue | Fix | Tests |
|---|---|---|
| **P1-1** GRANT_LEASE insufficient branch did not persist refill | Single-key script made isomorphic with TOKEN_BUCKET: **the insufficient branch likewise writes back post-refill tokens/ts and updates the bucket TTL**; GRANT_MULTI keeps "insufficient ⇒ no write" (required by the multi-key all-or-nothing semantics; structural difference recorded as-is) | Real integration 4 assertions: granted=0/no record/ts only moves forward/bucket TTL written back/unified semantics |
| **P1-2** Bucket state numeric range validation missing | GRANT_LEASE/RETURN_LEASE stage 1 completed: tokens∈[0,capacity], ts≥0, finite numbers (NaN/±inf rejected), granted a positive integer <2^53 — **invalid rejected with data unchanged (no silent correction)** | Real integration 8 assertions: negative tokens/over capacity/negative ts × GRANT/RETURN + invalid granted ×2 |
| **P1-3** wait return semantics undefined | Unified with the TOKEN_BUCKET contract: computed from **post-debit** tokens (partial grant wait>0) | Partial grant (tokens=2.5/batch=5/rate=0.016): granted=2, remaining 0.5, wait=31.25s exact assertion |
| **P2-4** Lease Key placeholder ambiguity | design.md notes that `{...}` in `kong:rl:lease:{lease_id}` is a placeholder, not a Hash Tag; the actual key has no braces (bare-run matrix consistent with implementation); Cluster slot consistency is Deferred | Static check |

**Note on historical differences in TOKEN_BUCKET/GRANT_MULTI**: the two scripts have only tonumber-level validation (no range checks) and belong to the already-accepted Phase 1/3 paths — per the "no incidental refactoring" principle they are **not modified**; the difference is recorded here (their inputs are derived by the existing caller from conf; risk is controlled).

### Test Results After Fixes

- `test/lease-redis-matrix.sh`: **PASS=39 FAIL=0** (including 12 new assertions: insufficient-branch persistence ×4, wait contract ×1, range validation ×8)
- `test/evalsha-unit.sh` (Phase 2 regression): **PASS 8/8**
- Dual-source diff ×4: **PASS**
- quota/dims/rules: **NOT RUN** (this group did not wire the request path; mandatory re-run in the Phase 6 integration stage)

### Defects in the Test Scripts Themselves Recorded During Fixing (all matrix-script issues; zero defects in production scripts)

1. redis-cli TIME outputs two lines (seconds + microseconds); bare `awk '{print $1}'` outputs two lines ⇒ pre-seeded ts has two lines ⇒ grant's ts read check rejects — all TIME reads add `NR==1`.
2. `$(( $RC TIME ... ))` double parentheses = arithmetic expansion (set -u reports unbound variable) — changed to single parentheses `$()`.
3. The HSET of the partial-grant/tokens<1 cases ran before fresh (DEL bucket) and got deleted — unified: fresh first, pre-seed after.
4. multi_bucket call passed one extra ARGV (ttl=1ms bucket expiring in seconds) — fixed.
5. The requested=0 test scenario mistakenly set granted=0 (conflicting with P1-2's granted≥1 validation) — changed to granted≥1 + requested=0 (spec semantics: requested=0 means fully consumed; granted itself ≥1).
6. `dexec $RC` double exec, docker cp failing with a service name — fixed (full container names).

## 8. Git Commit

- Group 1: `feat: add redis lease grant and return scripts`
- Round-one fixes: `fix: phase3 group1 review fixes (refill persistence, validation, wait contract)`
- Round-two fixes: `fix: phase3 group1 round2 (wait order, ttl validation bounds, wait test rewrite)`

## 9. Unresolved Issues

Same as Group 1 report §6 (call wrapper Phase 4, schema lifecycle parameters Phase 5, monotonic clock verification as a Phase 5 precondition, Cluster Deferred). No new items.

- `feat: add redis lease grant and return scripts` (everything in this group: two scripts + registration + matrix + injection generator + documentation ruling sync)
