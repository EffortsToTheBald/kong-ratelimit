# REMEDIATION Record (rate-limit-advanced)

- Baseline: `c9e05fc9fb8079d96c797f069e4aeb068ee7e2ce` (tag `baseline-c9e05fc` created)
- Branch: `remediation/hardening` (created from the baseline; this file and the two probe scripts have been committed and pushed to origin; commit hashes in "Commit Status" at the end)
- Gate 1 status: **Supplementary testing complete** (see the "Gate 1 Supplementary Test Evidence" section of this document). Baseline regression: all 16 test entry points PASS; memory probe run (measured); concurrency probe run (Lua coroutine interleaving model, real OpenResty concurrency verification NOT VERIFIED); Worker RSS NOT RUN.
- Gate 2 status: **Final freeze** (see the "Gate 2 Final Freeze" section; MAX_POOLS=10000, max_age=2×window, 60s Timer cleanup, and Plan B are all locked in).
- N3 (Cluster CROSSSLOT): **No authorization granted; record-only, no modifications**.

---

## Gate 1 Supplementary Test Evidence (2026-11-15, branch remediation/hardening, baseline unmodified)

### Execution Environment

- Docker Compose: `kong:3.6` ×3 (kong1/kong2/kong3, 2 Workers per replica) + redis + echo (all Up/healthy)
- Lua test execution method: `docker compose cp test/<x>.lua kong1:/tmp/<x>.lua && docker compose exec -T kong1 resty /tmp/<x>.lua` (Shell wrappers: all `test/*.sh` follow this pattern; these are pre-existing repo entry points, no new wrappers created)
- LuaJIT 2.1.0-20231117 (inside the kong1 container)

### Baseline Regression (commands = each `bash test/<x>.sh`, all pre-existing repo scripts; raw output preserved in this round's execution logs)

| Test Entry | Type | Assertions | Status |
|---|---|---|---|
| evalsha-unit.sh | Unit | 8 | PASS |
| lease-unit.sh | Unit | 25 | PASS |
| algorithm-lease-unit.sh | Unit | 17 | PASS (the runtime `_G write guard` warn comes from the test stub writing the global kong table, not a failure) |
| config-isolation-unit.sh | Unit | 15 | PASS |
| lease-grant-smoke.sh | Real Redis smoke | 4+7 | PASS |
| lease-redis-matrix.sh | Bare-Redis matrix | 50 | PASS |
| lease-isolation.sh (lease-iso.lua dual VM) | Isolation | 7 | PASS |
| concurrent-lease-e2e.sh | Real OpenResty multi-Worker E2E | 17 | PASS (includes 270-concurrency measurement: GRANT=10, Σgranted=100, HTTP allowed=100) |
| lease-exhaustion-e2e.sh | E2E | 11 | PASS |
| config-isolation-e2e.sh | E2E | 14 | PASS |
| algorithm-lease-e2e.sh | E2E | 15 | PASS |
| fault-recovery-e2e.sh | E2E | 14 | PASS |
| handler-fault-e2e.sh | E2E | 26 | PASS |
| lease-timeout-uncertain-e2e.sh | E2E | 22 | PASS |
| script-cache-selfheal-e2e.sh | E2E | 15 | PASS |
| worker-crash-e2e.sh | E2E | 16 | PASS (ledger: Σgranted=100=HTTP allowed 94+lost 6) |

Summary: **all 16 entry points PASS, 0 FAIL, 0 NOT VERIFIED** (pre-fix baseline).

### Probe 1: test/lease-memory-baseline.lua (new file, read-only against production code)

- Command: `docker compose exec -T kong1 resty /tmp/lease-memory-baseline.lua`
- Scenario: 100,000 distinct pool_keys; each pool registers 1 Lease (granted=10) and consumes 3.
- Raw output (measured):
  - baseline_heap_kb=262.5 → after_alloc=67504.9 KB → unchanged after GC (67504.9, objects still alive) → 1305.8 KB after `lease.reset()` (**measured evidence of object collectability**)
  - delta=67242.4 KB / 100,000 pools ⇒ **689 B/pool (derived, includes 1 ACTIVE Lease + pool structure)**
  - stats and invariants: leases=100000 granted=1000000 consumed=300000 active=100000 local_remaining=700000, identity holds, invariants=true → RESULT: pass=1 fail=0
  - Additional inline measurement (same single command execution, not a file): marginal cost of appending a 2nd Lease to the same pool = **323 B/Lease (derived)**
- Meaning of memory metrics (layered declaration per supplementary constraint 2):
  - `collectgarbage("count")` = **LuaJIT GC heap KB**, Lua objects only; excludes nginx, excludes process RSS, excludes other Workers.
  - This probe belongs to **Layer 1 (Lua unit probe)**: it only proves object lifecycle/collectability and Lua heap cost.
  - **Layer 2 (real Worker memory) NOT RUN**: requires real traffic with 100,000 distinct dimension values (current k6/latency.js hits a fixed /echo, no per-request dimension variation), requiring a new k6 scenario varying by header — beyond the scope of files allowed to be added this round; to be executed after authorization (draft command in Open Questions).
  - **Layer 3 (long-duration soak) NOT RUN**.
  - This probe's GC numbers must not substitute for Worker RSS (supplementary constraint 2 observed).
- Calibration of the MAX_POOLS estimate: see Gate 2 §2 "Calibration".

### Probe 2: test/lease-concurrent-grant-probe.lua (new file, read-only against production code)

- Command: `docker compose exec -T kong1 resty /tmp/lease-concurrent-grant-probe.lua`
- Injection method: `lease._transport` replaced with a fake transport layer that does `coroutine.yield` ×TICKS (same technique as the injection in algorithm-lease-unit.lua); coroutines yield only inside the transport layer, yield points coincide with cosocket yield points; TAKE/registration sections remain non-yielding.
- **Fidelity statement: the scheduler is an ordinary Lua loop, not OpenResty cosocket/event scheduling ⇒ this probe is a Lua coroutine interleaving model; real OpenResty concurrency verification NOT VERIFIED**. Real-environment comparison data point (measured, from concurrent-lease-e2e.sh): 270 concurrent / 6 Workers ⇒ total GRANTs=10, Σgranted=100, no pile-up (arrivals spread over seconds vs Redis RTT in milliseconds).
- Measurement definitions: in-flight GRANT = calls that have entered the transport without receiving a response; registered Lease count = length of pool.leases; confirmed_granted = Σgranted; consumed = tokens_consumed; outstanding = local_remaining; uncertain_lost = 0 (transport always succeeds).
- Raw output (measured):
  - burst (all N enter GRANT simultaneously, batch=10, TICKS=5):
    | N | grant_calls | max_inflight | leases | confirmed_granted | consumed | outstanding |
    |---|---|---|---|---|---|---|
    | 2 | 2 | 2 | 2 | 20 | 2 | 18 |
    | 10 | 10 | 10 | 10 | 100 | 10 | 90 |
    | 50 | 50 | 50 | 50 | 500 | 50 | 450 |
    | 100 | 100 | 100 | 100 | 1000 | 100 | 900 |
  - steady (1 new request per scheduling step, TICKS=5): grant_calls=10, max_inflight=5, leases=10, confirmed_granted=100, consumed=100, outstanding=0.
- Conclusions (all marked NOT VERIFIED, pending real E2E re-verification):
  1. **In-flight GRANTs are unbounded**: burst N=100 ⇒ 100 concurrent in-flight grants on a single pool, 100 Leases registered.
  2. **A single Worker's local inventory for a single key can far exceed batch**: N=100/batch=10 ⇒ confirmed_granted=1000, outstanding=900 (=90×batch). Limited only by the number of concurrent requests, not by any code-level cap.
  3. **In-flight count ≈ arrival rate × RTT (steady scenario)**: when inter-arrival time exceeds RTT, in-flight ≈ 1–5 and inventory is naturally bounded; pile-up occurs only with bursty simultaneous arrivals — consistent with the concurrent-lease-e2e measurement of "no pile-up under second-scale arrival distribution".
  4. The ledger identity holds in all scenarios: confirmed_granted = consumed + outstanding + 0.

### Items Not Runnable / Not Run

- Worker RSS (Layer 2): NOT RUN. To run after authorizing a new k6 scenario varying dimensions per request: `k6 run` with high-cardinality headers against kong1 → sample `/proc/<worker pid>/status` VmRSS before/after for comparison.
- Long-duration soak (Layer 3): NOT RUN.
- Real-environment concurrency probe (real cosocket + ngx.sleep injection inside a Kong Worker): NOT VERIFIED. The current resty model can only prove the behavior order under coroutine interleaving and is not a substitute.

## Gate 2 Final Freeze (2026-11-15, awaiting Gate 3 implementation)

The following parameters and plans are **frozen**; Gate 3 must implement them as-is and may not deviate unilaterally:

| Frozen Item | Frozen Value | Notes |
|---|---|---|
| MAX_POOLS | **10000 / Worker** (Lua constant, no schema change) | Memory measured calibration: 6.9 MB/Worker mean, 10.1 MB worst case (2 Leases/pool) |
| max_age | **2×window** (configuration snapshot at each Pool's first GRANT) | Same value as bucket key TTL, prevents crossing bucket epochs |
| Timer cleanup | **init_worker `ngx.timer.every(60, sweep)`** (60s) | ≤64 Pools per tick, wrapped in pcall, exiting check, touches only idle Pools |
| Concurrent GRANT | **Plan B: single in-flight GRANT per Pool + remaining concurrent requests degraded to batch=1 direct grants** | Direct grant = `redis_mod.grant(conf, key, 1, ...)`, no local lease pool registration |
| Ledger identity | **confirmed_granted = consumed + outstanding + discarded** | uncertain_lost tracked separately, excluded from the identity; no retry, no registration (semantics frozen) |

**Frozen behavioral rulings (changes relative to the previous draft, in diff form)**:

```diff
- Eviction order: prefer pools without ACTIVE Leases; when none evictable, evict by
- oldest last_used, including pools holding ACTIVE Leases, with remaining counted as discarded.
+ Eviction order: only pools without ACTIVE Leases are evicted (zero inventory loss).
+ When MAX_POOLS is at its cap and no evictable idle Pool exists, no ACTIVE Pool is
+ evicted; the request degrades directly to the batch=1 direct grant path
+ (no 429, no 503; see §2).
+ ⇒ EVICTED no longer produces inventory loss; the sole source of discarded_tokens =
+   unconsumed remaining of EXPIRED Leases; never automatically returned to Redis.
```

- EVICTED definition revised accordingly: EVICTED means only "an idle Pool deleted wholesale under MAX_POOLS pressure", with no Lease object loss; `_counters.evicted` counts deleted Pools (diagnostic), not part of the ledger identity.
- Unchanged (still in effect): Worker RSS (Layer 2), long-duration soak (Layer 3), and real OpenResty concurrency verification = NOT RUN / NOT VERIFIED; real verification must be added after the Gate 3 fix.
- **N3 (Redis Cluster CROSSSLOT): explicitly no authorization to modify this round**. Keep the "confirmed conditional compatibility issue" record; `redis/*.lua`, the embedded scripts in `lib/redis.lua`, and the frozen Redis Lua protocol stay untouched, pending separate later approval.
- No production code, Redis keys, Lua protocol, or Schema modifications this round.

---

## Gate 2: Remediation Design (no code changes in this gate; this file is the only addition)

### What Changed

No code changes. Only `docs/REMEDIATION.md` was added. The design below is based on direct verification of the current code; all files live under `kong/plugins/rate-limit-advanced/` (prefix omitted below).

### Design Premises: Verified Code Facts (where the Gate 1 leads land)

| Lead | Verification Result | Evidence (file:line) |
|---|---|---|
| a. register only appends, never deletes; no reclamation, no timer | **Confirmed** | `lib/lease.lua:124-125` (leases/active each appended once); `:156-158` (exhaustion only removes from active, object kept in leases); no deletion point anywhere in `_M._pools`; `handler.lua:18-20` (init_worker only logs); grep across the directory finds no `ngx.timer` |
| b. check_lease GRANTs directly on local inventory miss, no merging/locking | **Confirmed** | `lib/algorithm.lua:350` (take→NEED_GRANT) → `:370` (direct lease.grant) → `lib/redis.lua:722` (EVALSHA, cosocket yield point) → `:239` (register registration). Concurrent requests each traverse this chain ⇒ multiple Leases coexist per pool |
| c. lkey has no hash tag; scripts only use caller-supplied KEYS | **Confirmed** | `lib/redis.lua:715` (`lkey = key_prefix .. ":lease:" .. lease_id`, no braces); bucket keys carry a hash tag (`lib/algorithm.lua:139`); GRANT_LEASE uses only `KEYS[1]/KEYS[2]`, RETURN_LEASE uses only `KEYS[1]/KEYS[2]`, scripts construct no keys internally (`lib/redis.lua:175-282, 292-399`). **Consequence: under Redis Cluster the two keys almost certainly land in different slots, EVAL with multiple keys reports CROSSSLOT, and the entire GRANT_LEASE path fails → fail-close 503** |
| d. dim_value concatenated without escaping; unauthenticated falls back to "anon" | **Confirmed** | `lib/algorithm.lua:133` (`dim .. "=" .. dim_value(...)` direct concatenation); `:66-68` (consumer nil ⇒ "anon") |
| e. Readers of Redis Lease metadata | **Confirmed**: no readers in production code. The RETURN_LEASE script is registered but has no call site (`lib/redis.lua:292` definition, grep finds no `return_lease` call); read only by tests: `test/worker-crash-e2e.sh:85,123` (`--scan --pattern 'kong:rl:lease:*'`), `test/lease-grant-smoke.lua` (HGET forensics) |
| f. Redis script arguments contain no local time; ngx.now used everywhere | **Confirmed**. The three scripts' ARGV are only batch/lease_ttl_ms/lease_id/pool_key/rate/capacity/bucket_ttl_ms, rate/burst/want/ttl_ms, n/rate/burst/ttl_ms — **no time arguments**; scripts uniformly use `redis.call('TIME')` (`lib/redis.lua:35,94,241,379`). Full inventory of local `ngx.now()` uses: `lib/lease.lua:69` (random seed), `:121` (created_at), `lib/algorithm.lua:266,341,433` (Reset header approximation), `handler.lua:70` (429 Reset header). **Conclusion holds: local time never participates in Redis-side authorization computation** |
| g. 5 tests that read internal structures | **Confirmed**, with respective intents: `lease-unit.lua` (register fields/conservation/TAKE atomicity/GRANT four-way classification, directly reads `lease._pools[PK].leases/active`); `algorithm-lease-unit.lua` (three-mode wiring matrix, `_transport` injection + redis_mod monkeypatch); `config-isolation-unit.lua` (pool_key fingerprint isolation + Pool-level isolation); `lease-grant-smoke.lua` (real Redis GRANT path + CLIENT PAUSE uncertain-direction forensics); `lease-iso.lua` (dual process = dual VM isolation, reads `_pools` for output) |
| h. design.md leftovers and README examples | **Confirmed**: `docs/design.md` still has 4 shared dict descriptions (:64,:240,:281,:360, inconsistent with the post-Phase-8 state after store.lua deletion) and 6 `⟨TODO⟩` marks (:288,:330,:348,:381,:395 etc.); README `:53` (limit=100 example), `:70` (3 replicas×2 Workers), `:104` (batch=10), `:124` (kong.yml limit=1000). Reasonableness assessment in §7 New Findings |

### 1. State and Ledger

**Pool lifecycle**

- Creation: `register()` creates a Pool on first encounter of a pool_key (`lib/lease.lua:86-93`). The Pool records: the `active` set, `last_used` (assigned once at TAKE), `max_age` (configuration snapshot at the pool's first GRANT, equal to 2×window, in **milliseconds**), and `sweep_seq` (marker against duplicate reclamation). **Unit convention (frozen)**: `created_at` and `ngx.now()` are in **seconds**, `pool.max_age` in **milliseconds**; all expiry/reclamation checks uniformly use `created_at + pool.max_age / 1000 < ngx.now()`.
- Reclamation: the entire pool is deleted when **all** conditions hold: (1) `#pool.active == 0`; (2) elapsed since `last_used` ≥ `max_age / 1000` (second scale, i.e., untouched for a bucket TTL window). Deletion happens only in the cleanup flow (§4); no O(n) scan on the TAKE/GRANT hot path.
- Reclamation boundary: the pool object (table + array) is released wholesale; no stepwise nil-ing.

**Lease terminal-state definitions** (once an object reaches a terminal state it is **immediately dereferenced and left to GC**; terminal-state objects are not retained — this modifies current D2 "objects retained for diagnostics"; rationale: the diagnostic list is precisely the unbounded-growth source; history is carried by counters instead)

- `ACTIVE`: in the pool.active set, remaining > 0, not past max_age.
- `CLOSED`: remaining decremented to 0, removed from active (current semantics unchanged, `lib/lease.lua:155-158`).
- `EXPIRED`: `created_at + max_age / 1000 < ngx.now()`, removed from active; **when remaining>0 it is counted into discarded (the sole source of discarded); when remaining=0 it is only removed**. **Never automatically returned to Redis** (V1 has no RETURN).
- `EVICTED` (frozen revision): means only "an idle Pool deleted wholesale under MAX_POOLS pressure" — **pools holding ACTIVE Leases are never evicted**, so EVICTED entails no inventory loss and no Lease object enters this terminal state; `_counters.evicted` counts deleted Pools (diagnostic), not part of the ledger identity.

Terminal-state visibility: `_counters` gains three numeric counters `expired` / `evicted` / `discarded_tokens`; `stats()` reports them. Terminal-state objects are not retained.

**Separation of runtime inventory from historical statistics**

- Runtime = the pool.active set (consumable inventory).
- History = `_counters` numeric counters (leases / tokens_granted / tokens_consumed / closed / expired / evicted / discarded_tokens). Counters are numbers, inherently bounded (Lua double limit 2^53, unreachable within lifespan), **no unbounded growth**. The `pool.leases` diagnostic list that formerly carried "history" is abolished.

**Ledger identity and scope of application (per this gate's requirement)**

```
confirmed_granted = consumed + outstanding + discarded
```

- `confirmed_granted` = the `tokens_granted` counter = Σ granted of Leases successfully registered. **Includes only GRANTs whose response the Worker received and registered**.
- GRANT timeout/disconnection/malformed responses (Redis may already have debited the bucket and created the record while the Worker did not register) are tracked separately as `uncertain_lost`, **not part of the identity above**. The current "no retry, no registration" semantics are unchanged (`lib/lease.lua:236-243` preserved verbatim, including the existing classification of register failures as uncertain).
- Conditions for the identity to hold **exactly**: at EXPIRED removal, remaining is transferred once into discarded_tokens; TAKE decrements and counters are updated within the same non-yield section (current `lib/lease.lua:152-154` already does this). Per-object conservation `granted = consumed + remaining` becomes `granted = consumed + discarded` at the moment of removal. EVICTED produces no discarded (frozen: ACTIVE Pools are not evicted).
- **Do not claim** the identity covers uncertain_lost: in `granted(global) = consumed + outstanding + discarded + uncertain_lost`, uncertain_lost can only be estimated by reconciling the Redis side against the Worker side (no reconciliation mechanism exists today); the document states only "loss allowed, direction conservative (under-grant)".

**Ledger accounting under Redis Cluster**: until CROSSSLOT (premise c) is fixed, Lease mode is unusable on Cluster; the fix (adding a hash tag to the lease key) **is a change to parameter/key construction of the dual-source scripts in `redis/*.lua`**, which under the remediation boundary must be reported and confirmed first; this design does not implement it unilaterally (see §7-N3 and Open Questions).

### 2. Pool Cap and Eviction

**MAX_POOLS = 10000 / Worker (Lua constant, no schema field change)**, rationale (single-point measurement + derivation; calibration data in "Gate 1 Supplementary Test Evidence" Probe 1):

- Per-Pool fixed cost: **measured calibration** — a pool with 1 ACTIVE Lease costs 689 B/pool (Probe 1), each additional Lease +323 B (derived, inline measurement).
- Cap memory (derived from the measured single point): 10000 Pools × average 1 ACTIVE Lease ≈ 10000 × 689 B ≈ **6.9 MB/Worker**; worst case (2 Leases per Pool) ≈ 10000 × 1012 B ≈ **10.1 MB/Worker**. Consistent with earlier estimates (7/14 MB); the measured calibration values are adopted.
- Why not a smaller value: the normal business cardinality (consumer×ip×path combinations) is usually < a few thousand; 10000 guarantees normal traffic **never triggers eviction**, so eviction only bites at attack-scale cardinality.
- Why not a larger value: the cap exists to bound attack memory, not to carry normal load; a larger value lets attack memory grow linearly.
- Explicit: this is a **per-Worker cap** (Workers own private Lua VMs, structurally no sharing). Total local lease pool for an N-Worker cluster = N × 10000 Pools × batch — unrelated to over-granting of the global rate limit (the global authority is the Redis bucket debit; see the clarification in §5).

**Eviction order (frozen)**: only **Pools without ACTIVE Leases** are evicted (zero inventory loss).

**Degraded path when the cap is reached and no evictable Pool exists (frozen; no eviction of ACTIVE Pools, no 429, no 503)**: the request degrades to a **direct authorization without local lease pool registration** — reusing the current batch=1 path `redis_mod.grant(conf, key, 1, ttl_ms, rate, burst)` (`lib/algorithm.lua:450`, want=1); granted≥1 ⇒ allow (remaining follows that path's existing convention = granted-1 = 0); granted=0 ⇒ the existing 429 semantics (this stems from an **empty bucket**, not attacker-manufactured Pool pressure); Redis failure ⇒ the existing fail-close/fail-open branches. Request semantics are identical to batch=1; an attacker cannot use high-cardinality keys to push normal users to 429/503 — Pool pressure only affects "whether the request enjoys the local inventory speedup", never the authorization result. This path does not enter the Lease ledger (no Lease registration) and logs a `pool_cap_degraded` marker for audit.

**TAKE hot-path constraint**: within TAKE, only the existing traversal plus a **single field assignment** `pool.last_used = now`; no linked lists, no O(n) maintenance. **Expiry check (frozen revision)**: TAKE performs one O(1) expiry comparison on each scanned candidate Lease (`created_at + pool.max_age / 1000 < ngx.now()`, unit convention in §1, details in §10) — on encountering an expired candidate it removes it and continues; on encountering the first non-expired consumable Lease it consumes. In steady state the head candidate is unexpired ⇒ zero hot-path overhead. The old wording "no expiry check" is abolished (it would let expired Leases in continuously-visited Pools live forever and be consumed — the Timer only cleans idle Pools, and GRANT's lazy sweep only triggers on NEED_GRANT; neither covers hot Pools).

**Eviction trigger points and cap**: eviction fires only (1) once on the GRANT path when the `_pools` count reaches MAX_POOLS, and (2) in the init_worker timer; each pass handles ≤ 64 Pools, never a full scan.

**Eviction and over-granting**: the remaining discarded by EVICTED is inventory already debited from Redis but unconsumed by the Worker — discarding is a loss, direction conservative (under-grant), **never over-granting**; never automatically RETURNed to Redis (V1 has no RETURN; `RETURN_LEASE` remains unwired).

### 3. Expiry

**max_age = 2×window (snapshot per Pool at its first GRANT, not a global constant)**, rationale:

- Same value as the bucket key TTL (current `lib/algorithm.lua:342`: `ttl_s = max(1, floor(window×2))`). Window meaning: from a Lease's creation, its corresponding bucket disappears wholesale at latest after 2×window; after the bucket disappears the new bucket starts full; if old local inventory survives across the bucket lifecycle, it would stack on the new epoch (a time-distribution burst, not over-granting — those tokens were already debited from Redis in the old epoch). max_age = 2×window guarantees local inventory never crosses bucket epochs.
- It also covers consumption pacing: auto batch ≤ limit/2, so the slowest single-batch consumption completes within ≤ window (Phase 6 report convention: 720s < 2×window=7200s at limit=100/window=3600; derived).
- **Conceptual distinctions (must be stated separately in documentation)**:
  - Bucket refill: the Redis side continuously generates tokens by `TIME` (`lib/redis.lua:47-51`), the **sole token source**.
  - Bucket TTL: the Redis-side key lifetime (PEXPIRE).
  - Local max_age: the Worker-side **discard** timer for inventory — it only removes available inventory, never generates it.
- **Time-source conclusion (verified, see premise f)**: Redis script arguments contain no local time; Redis-side authorization depends only on `redis.call('TIME')`. Therefore: local clock jumping forward ⇒ max_age expires early ⇒ only **earlier discard**; clock rollback / inter-node skew ⇒ max_age delayed ⇒ inventory lives slightly longer, still tokens already debited from Redis, **creating no tokens**. Conclusion: **cumulative grants ≤ cumulative confirmed Redis debits (including debits on the direct-grant path), independent of local clock behavior**.
- **Documentation boundary (per supplementary constraint 3)**: the preceding sentence holds given that Redis authorization state is continuously valid, no confirmed writes are rolled back, and the statistics conventions are consistent. The following cases must be stated separately and must not be absorbed into that sentence:
  1. **Redis primary failover / data rollback**: a debited bucket rolls back to an old value ⇒ the same batch of tokens may be granted again ⇒ this is **true over-granting**, belonging to the Redis fault domain; this design does not claim protection against it.
  2. **Policy fingerprint change**: old and new Buckets coexist (fingerprint isolation at `lib/algorithm.lua:136-139`), old Pools die out naturally per max_age — during coexistence the total grant is "each epoch per its own quota"; the document describes this factually; it is neither over-granting nor a protection target.
  3. **Local-clock safety ≠ system-wide fault-domain safety**: the entire function of the local expiry mechanism is "discard"; it provides no over-grant protection against Redis-side faults.
- Qualification of the consequence when rollback lets inventory survive beyond max_age: an **extension of the existing burst-amplification semantics** (the Worker keeps granting with old inventory until exhausted), not new over-granting. No FFI monotonic clock is introduced (Phase 5 already DEFERRED; this remediation does not restart that work).

### 4. Cleanup

- **TAKE/GRANT lazy cleanup**: before GRANT (within a non-yield section), one bounded expired sweep on **the current pool**: remove EXPIRED Leases, increment discarded counters; at most 32 Leases per pass, the rest left for next time (GRANT is a cold path, batching allowed). TAKE does no full cleanup, but **removes expired Leases opportunistically while scanning candidates** (O(1) comparison + removal as it scans, see §10) — expired reclamation for hot Pools is carried by the TAKE path; the Timer only backstops idle Pools.
- **init_worker backstop timer (frozen: 60s)**: `ngx.timer.every(60, sweep)` (low-frequency; interval 60s; derivation: 2×window typically = 60~7200s, 60s granularity has negligible effect on discard timing). Each tick:
  - If `ngx.worker.exiting()` is true ⇒ return immediately (Worker exiting).
  - The callback is wholly wrapped in `pcall`; a per-pool exception ⇒ log the error and skip that pool without affecting others.
  - Only "idle candidates" are processed: Pools whose `last_used` is ≥ `max_age / 1000` ago (second scale), ≤ 64 per tick (oldest `last_used` first), never a full scan.
  - **No duplicate reclamation with the request path**: the request path touches only "the current request's pool"; the timer touches only "idle pools" (last_used older than the threshold ⇒ no request is using it). The two sets are disjoint; no locks needed.
  - Interleaving safety between timer and request coroutines: cleanup consists entirely of pure table operations with no yield points; any cleanup section is mutually exclusive with TAKE/GRANT non-yield sections under coroutine scheduling (same shape as the existing atomicity argument; `lib/lease.lua:8-10` comment's proof method reused directly).
- Second backstop duty: eviction at MAX_POOLS can also be carried by this timer, reducing the chance of triggering on the request path.

### 5. Concurrent GRANT (mechanism verified; quantities from probe measurements + the Lua coroutine model; real-environment conclusions NOT VERIFIED)

**Mechanism (verified, premise b)**: check_lease local miss ⇒ each concurrent request issues its own GRANT (cosocket yield, `lib/redis.lua:722`), no in-flight merging, no cap.

- **In-flight GRANT definition**: the count of GRANT calls whose EVALSHA has been sent but whose response has not been received (per Worker per pool). Current code has no counter and no cap.
- **Measured (Lua coroutine interleaving model, NOT VERIFIED, see supplementary-testing Probe 2)**:
  - burst N=100, batch=10: max_inflight=100, 100 Leases registered on a single pool, confirmed_granted=1000, outstanding=900 (=90×batch) — **per-Worker per-key inventory cap = concurrent request count × batch, unconstrained by any code**.
  - steady (inter-arrival > RTT): max_inflight=5, leases=10, inventory naturally bounded ⇒ pile-up appears only on bursty simultaneous arrivals.
  - **Real-environment comparison (measured, concurrent-lease-e2e.sh)**: 270 concurrent / 6 Workers, total GRANTs=10, Σgranted=100 — no pile-up under second-scale arrival distribution. The two data points do not conflict: in real deployments pile-up probability = same-pool arrival density × Redis RTT; still requires re-verification by a real OpenResty probe (NOT VERIFIED).
- **Harm clarification (unchanged)**: the total is never over-granted — every GRANT atomically debits the Redis bucket; actual harms are (1) memory pile-up (backstopped by §2 MAX_POOLS), (2) burst amplification (future quota borrowed locally in advance), (3) larger crash-loss exposure.

**Plan comparison**:

| Plan | Description | Throughput/Latency | Semantic Impact | Assessment |
|---|---|---|---|---|
| A keep status quo | no merging, no cap | on a miss storm, all requests hit Redis concurrently (they would anyway) | unchanged | Measured (NOT VERIFIED): under burst, per-pool Lease count = concurrency, inventory = concurrency×batch; memory/burst/loss exposure unbounded (memory backstopped by §2 MAX_POOLS), burst amplification persists |
| B single in-flight GRANT per Pool + remaining concurrency degraded to direct grant | pool records an `inflight` flag; while set, concurrent requests go directly through `redis_mod.grant(want=1)` (no registration) | hot path unchanged; the direct grants added on the miss path are one Redis call per request, same cost as batch=1 | request semantics unchanged (authorization still decided by the Redis bucket, empty bucket still 429); the no-retry/no-registration semantics hold naturally for this degraded path | **Recommended (probe data strengthens the case)**. Steady measurements show that when inter-arrival > RTT, in-flight is already bounded ⇒ B only takes effect in burst windows, cost minimal; O(1) bookkeeping, no coroutine coordination. **Per-Pool active Lease count bound = 1 (frozen)**: GRANT is issued only when take returns NEED_GRANT (active empty); the single in-flight flag ensures at most one GRANT per Pool at any instant; concurrent requests while the flag is set go direct without registering; after GRANT returns, classify + register and flag clearing complete within the same non-yield section (no yield point between) ⇒ at any moment `#pool.active ≤ 1` |
| C merge-and-wait | later requests yield waiting for the in-flight GRANT result to share inventory | introduces coroutine waiting/timeout propagation; complex to implement | request latency becomes coupled to the in-flight GRANT's RTT | Not recommended: complexity disproportionate to benefit, and the waiting semantics must be built anew |
| D per-Pool Lease count cap + over-cap degraded direct grant | equivalent to B but different bookkeeping object (count Leases, not in-flight) | same as B | same as B | Can serve as an implementation variant of B; B's flag is simpler |

**Recommend B, rationale**: the degraded path reuses **the batch=1 path already validated by 66 assertions** (`lib/algorithm.lua:448-484`), with fail-close/429/header semantics all in place; minimal implementation surface (one flag + one branch); changes no frozen semantics. **Implementation risk requires design confirmation**: the inflight flag must be cleared on all GRANT return paths (including timeout exceptions), otherwise the pool degrades permanently — implement with non-yielding paired set/clear.

### 6. Test Plan (three categories kept separate, never substituted for one another)

**Unit (resty, extensions of the existing framework)**
- New assertion surface: EXPIRED removal + discarded count; EVICTED removal + discarded; MAX_POOLS degraded direct grant (batch=1 path invoked, no registration); Pool reclamation (active empty + last_used older than max_age/1000); **Plan B bound: under burst N concurrency (probe-style coroutine injection), the transport is called exactly once, the direct-grant stub N−1 times, and at the end `#pool.active ≤ 1`**; the ledger identity `confirmed_granted = consumed + outstanding + discarded` holds on all paths; uncertain excluded from the identity (existing assertions kept).
- `_M.invariants()` extended to verify the new counters against per-object sums without drift (extension within the current `lib/lease.lua:295-340` framework).

**Synchronized modification of the 5 tests that read internal structures (preserving each one's original intent)**
- `lease-unit.lua`: intent = structure and conservation. Changes: the original "full diagnostic list retains objects" assertion (reading `pool.leases`) becomes "after an object reaches a terminal state, counters close the loop + the active set leaves no residue"; conservation/atomicity/GRANT four-way-classification assertions preserved as-is (the active set and stats they read still exist).
- `algorithm-lease-unit.lua`: intent = wiring matrix. Essentially unchanged; a new column added for "cap-reached degraded direct grant, no GRANT_LEASE touched".
- `config-isolation-unit.lua`: intent = pool_key isolation. Unchanged (the Pool-level structures it reads exist unchanged in the new design).
- `lease-grant-smoke.lua`: intent = real Redis path evidence. Unchanged (reads no `_pools` internals, uses public APIs).
- `lease-iso.lua`: intent = dual-VM isolation. Output lines now taken from `stats()` (the lines reading `_pools` replaced by equivalents), isolation assertions unchanged.

**Memory stress (recorded separately from unit probes; GC results must not substitute)**
- Layer 1 Lua unit probe: **already run (PASS, measured)** — `test/lease-memory-baseline.lua`, 100k pools, 689 B/pool, recovered to ~1 MB after reset; only proves object lifecycle and Lua heap cost.
- Layer 2 Worker stress: **NOT RUN** — plan: add a per-request varying-dimension k6 scenario hitting 100k distinct keys, record per-Worker `collectgarbage("count")` and `/proc/<pid>/status` VmRSS, one round before and one after the fix under identical environment/scale/procedure.
- Layer 3 long-duration soak: **NOT RUN** — plan: continuous create/consume/expire/evict cycles ≥ 1h, observe RSS and GC count convergence. The three layers' results are recorded separately in REMEDIATION.md; mixing is forbidden.
- Explicitly prohibited inference: "_pools count is bounded ⇒ memory is bounded" is not acceptable as a conclusion; Layer 2/3 measured numbers must close the loop (both currently NOT RUN).

### 7. New Issues Found (discovered during this gate's verification, outside the original lead list)

| # | Issue | Evidence | Risk |
|---|---|---|---|
| N1 | header dimension values >256 chars truncated (`MAX_DIM_VALUE_LEN`); different long values share the 256-char prefix ⇒ different tenants merged into the same bucket/same Pool | `lib/algorithm.lua:22,87-89` | P2 |
| N2 | Dimension value concatenation without escaping: a value containing the `:<dim>=` pattern can collide with other dimension combinations (e.g., IPv6 values contain colons, header values arbitrary) ⇒ cross-dimension bucket mixing | `lib/algorithm.lua:133,70-74` | P2 |
| N3 | Under Redis Cluster deployment the lease key has no hash tag ⇒ CROSSSLOT ⇒ GRANT_LEASE fails entirely (fail-close 503). Fix requires changing key construction at `lib/redis.lua:715` (synchronized with the `redis/grant_lease.lua` dual source) — **within the remediation boundary this is a no-touch zone; may proceed only after your confirmation** | `lib/redis.lua:715` vs `lib/algorithm.lua:139` | P1 (triggered only on Cluster deployments) |
| N4 | `RETURN_LEASE` script registered but never called by production code (dead code). Not deleted per the boundary; recommended to annotate in docs as "retained, unwired (for Phase 5 revival)" | `lib/redis.lua:292,421` | P3 |
| N5 | `stats()/invariants()` iterate all Pools × Leases, O(total); only test/diagnostic callers, no production hot-path references | `lib/lease.lua:267-284,295-340` | P3 |
| N6 | `LEASE_TTL_MS` fixed at 1h < bucket TTL (2×window; when window>1800s the bucket outlives the Lease record); no practical impact in V1 since there is no RETURN; will hit LEASE_NOT_FOUND when Phase 5 wires RETURN | `lib/algorithm.lua:20,342` | P3 |
| N7 | README example: limit=100 + batch=10 + 6 Workers ⇒ steady-state local inventory can reach 60 (60% of quota borrowed in advance), crash-loss exposure 6×10=60; numbers are functionally self-consistent but aggressive; suggest changing the example to `batch=5` or auto (auto=floor(100/50)=2) | `README.md:53,70,104` | P3 (documentation) |
| N8 | design.md retains 4 shared dict descriptions and 6 `⟨TODO⟩` marks, inconsistent with the post-Phase-8 state | `docs/design.md:64,240,281,288,330,348,360,381,395` | P3 (documentation) |

### 8. Risk Classification and Implementation Plan

Classification principle: P0 blocking / P1 correctness or long-term stability / P2 productionization gap / P3 documentation maintainability. **Not all are designated mandatory.**

| Issue | Files Involved | Risk | Tests | Needs Design Confirmation |
|---|---|---|---|---|
| a. Unbounded Lease object growth (leases list + _pools never reclaimed) | lib/lease.lua, handler.lua(timer) | **P1** | lease-unit extensions + three-layer memory | No (frozen) |
| b. Concurrent GRANT without merging (inventory pile-up / burst amplification / loss exposure) | lib/algorithm.lua or lib/lease.lua | **P1** (harm is memory and burst, not over-granting) | algorithm-lease-unit new column + before/after probe comparison | No (Plan B frozen; only the inflight flag's paired set/clear is an implementation detail) |
| Added: Pool cap + degraded direct grant | lib/lease.lua, lib/algorithm.lua | accompanying defense for P1 | algorithm-lease-unit new column | No (MAX_POOLS=10000 and no eviction of ACTIVE Pools frozen) |
| Added: max_age expiry cleanup | lib/lease.lua | accompanying defense for P1 | lease-unit + soak | No (2×window and 60s Timer frozen) |
| N3. Cluster CROSSSLOT | lib/redis.lua:715, redis/grant_lease.lua dual source | P1 (conditional) | lease-grant-matrix (Cluster environment) | **Yes (no-touch zone, requires approval)** |
| N1/N2. Dimension value collisions | lib/algorithm.lua dim_value/build_key | P2 | config-isolation-unit extensions | Yes (the escaping scheme changes the existing key shape ⇒ all existing buckets invalidated) |
| N7. README example numbers | README.md | P3 | none (documentation) | No |
| N8. design.md leftovers | docs/design.md | P3 | none (documentation) | No |
| N4/N5/N6. Record-keeping notes | — | P3 | none | No (record-only, no changes) |

**Recommended mandatory order**: a (unbounded growth) → b (concurrent GRANT) → N3 (pending approval) → N1/N2 (pending acceptance of the key-shape change). N7/N8 may be committed together with adjacent documentation changes (per supplementary constraint 5).

### 9. Post-Supplementary-Testing Design Re-Review (item by item, per the review requirements)

| Design Item | Re-Review Conclusion | Basis |
|---|---|---|
| MAX_POOLS=10000/Worker memory estimate | **Keep 10000; estimate updated to measured calibration**: 6.9 MB/Worker (mean) / 10.1 MB (worst 2 Leases/pool) | Probe 1 measured 689 B/pool, +323 B/Lease |
| max_age=2×window | **Kept**. Probe data does not touch time behavior; the original derivation chain (= bucket TTL, no bucket-epoch crossing, discard-only never generate) unchanged; the verification conclusion that Redis scripts contain no local time unchanged | Premise f verification + Probes 1/2 no conflict |
| Inventory handling when an ACTIVE Lease expires | **Kept: EXPIRED removal, remaining counted into discarded, never returned to Redis**. The ledger identity includes the discarded term; the probe-verified confirmed_granted = consumed + outstanding + 0 is compatible with this design (discarded>0 scenarios covered by post-fix tests) | Probes 1/2 identity_ok=true |
| Cap-reached batch=1 direct-grant degradation | **Kept**. The reused path `redis_mod.grant(want=1)` has real verification coverage: algorithm-lease-e2e.sh batch=1 column PASS (15 assertions), handler-fault-e2e.sh batch=1 fail-close/fail-open PASS — the degraded path's semantic foundation is already measured | This round's baseline regression |
| Single in-flight GRANT + direct-grant degradation (Plan B) | **Recommendation kept, rationale strengthened**: steady measurements (NOT VERIFIED) show in-flight is already bounded when inter-arrival > RTT (max_inflight=5, leases=10), so B only takes effect in burst windows; burst measurements (NOT VERIFIED) quantified the cost of no constraint (inflight=100, inventory 900=90×batch) | Probe 2 measurements + concurrent-lease-e2e measured comparison |

Final ledger convention (unchanged, consistent with probe measurements): `confirmed_granted = consumed + outstanding + discarded`; GRANT timeout/lost response → `uncertain_lost` tracked separately, excluded from the identity, no retry no registration (current `lib/lease.lua:236-243` semantics frozen unchanged).

### 10. TAKE Boundary for Expired Leases in Active Pools (clarified and frozen; no production code changes)

**Problem**: the Timer only cleans idle Pools, and GRANT's lazy sweep triggers only on NEED_GRANT; Pools continuously hit by requests (`last_used` constantly refreshed) are covered by neither — Leases past max_age inside them remain in the active set and get consumed by TAKE. Harm qualification: these tokens were already debited from Redis in the old epoch, **not cumulative over-granting** (§3 conclusion unchanged), but it defeats "local inventory never crosses bucket epochs" (the design purpose of max_age) on slow hot Pools — an extension of burst amplification in the time distribution — and must be fixed.

**Ruling 1: how to guarantee expired Leases in active Pools are no longer consumed by TAKE**

- TAKE performs a **per-candidate O(1) expiry comparison** while scanning: `created_at + pool.max_age / 1000 < ngx.now()` (unit convention: `created_at`/`ngx.now()` in seconds, `pool.max_age` in milliseconds, §1/§2/§3 frozen value 2×window millisecond snapshot).
- Candidate expired ⇒ call the unified removal function `expire_lease(pool, lease)` (§1 EXPIRED semantics): `state="EXPIRED"`, `discarded_tokens += remaining`, remove from the active array — all three steps within **the same non-yield section**; TAKE then continues to the next candidate.
- The first non-expired candidate with remaining>0 is consumed as usual; all candidates expired/no inventory ⇒ `NEED_GRANT` ⇒ the existing GRANT path (whose lazy sweep dovetails naturally with this logic).
- Clock semantics (per §3): local clock rollback ⇒ expiry deferred (inventory lives slightly longer, burst amplification extended, direction conservative); clock jump forward ⇒ fresh inventory discarded early (under-grant, conservative). Neither direction creates tokens.

**Ruling 2: why no O(n) scan is introduced on the TAKE hot path**

- **TAKE worst-case scan cost = O(1) (strictly, not amortized)**: under Plan B each Pool's active Lease count is bounded by 1 (§5 Plan B row, frozen). TAKE checks at most 1 candidate: non-expired with remaining>0 ⇒ consume and return; expired ⇒ `expire_lease` removes it (active becomes empty) ⇒ return NEED_GRANT. No path exists that "skips multiple candidates while scanning".
- Defensive amortized argument (retained, covering any abnormal state that breaks the bound): each Lease is removed at most once (once removed it leaves the active set and is never scanned again); total removals over its lifetime ≤ total registrations, so the total extra cost is amortized across all TAKEs.
- `table.remove` shifting cost: the active array length is itself bounded (after Plan B freezes, `#active ≤ 1`; and the current exhaustion removal already uses the same primitive, `lib/lease.lua:157`); no new asymptotic cost.

**Ruling 3: discarded counted exactly once, identity unbroken**

- **The single removal function** `expire_lease` is the sole entry point: the TAKE path, GRANT lazy sweep, and Timer backstop all call it; the counting logic exists in exactly one place (`discarded_tokens += l.remaining` together with setting `state` to EXPIRED and removing from active, within the same atomic section).
- Duplication prevention is guaranteed by mechanism: (a) a Lease object appears at most once in the active set (existing structural invariant, asserted by `lib/lease.lua:295-340`); (b) `state` flips **before** counting, and after removal the object leaves active ⇒ the second arriver (via any path) can never see it again; (c) all three call sites are non-yield sections, and coroutine scheduling guarantees no interleaving between sections (existing atomicity argument reused), so there is no window where "two paths remove the same object simultaneously".
- The identity is maintained as `confirmed_granted = consumed + outstanding + discarded`: at removal the transition `granted = consumed + remaining` → `granted = consumed + discarded` happens instantly; once remaining is transferred out it immediately leaves outstanding (active-sum convention), with no double counting.
- Verification requirements (Gate 3 test surface): lease-unit adds an assertion that "the same Lease processed consecutively by a concurrent path and the Timer counts discarded exactly once"; lease-unit adds an "expired head candidate" assertion (pre-seed 1 expired Lease ⇒ take returns NEED_GRANT, discarded increases exactly +remaining once, active emptied — simultaneously anchoring the O(1) worst-case scan); `invariants()` adds the global conservation check `discarded_tokens + Σactive.remaining + consumed == Σgranted` and the **per-Pool `#active ≤ 1` (Plan B bound)** check.
### Open Questions

- **Real OpenResty concurrency verification NOT VERIFIED**: Probe 2 is a Lua coroutine interleaving model; real cosocket + ngx.sleep injection must be done inside a Kong Worker (or reproduce pile-up with k6 high concurrency against a real slow Redis); after the Gate 3 fix, the fix's effect must be re-verified with real E2E.
- **Worker RSS (Layer 2) and long-duration soak (Layer 3) NOT RUN**: requires authorization to add a k6 scenario with per-request dimension variation (current k6/latency.js hits a fixed /echo and cannot produce high-cardinality keys); draft commands: k6 varying-dimension headers against 100k keys → `docker compose exec kong1 sh -c 'grep VmRSS /proc/<worker>/status'` before/after comparison.
- N3 (Cluster CROSSSLOT) **not authorized (re-confirmed this frozen round)**: keep the confirmed conditional compatibility issue record; do not modify `redis/*.lua`, embedded scripts in `lib/redis.lua`, or the Redis Lua protocol; await separate approval.
- Fixing N1/N2 changes the Redis key shape (existing buckets/Leases all invalidated once); requires your confirmation of acceptability.
- Worker RSS (Layer 2) and long-duration soak (Layer 3): NOT RUN (kept through this frozen round; real verification to be added after the Gate 3 fix).

### Commit Status (closing check 2026-11-15)

- `bd8804d` test: add lease memory and concurrent-grant probes (gate-1 evidence) — the two probe scripts
- `4db584f` docs: remediation baseline evidence and frozen gate-2 design — this file
- Pushed to `origin/remediation/hardening`; the working tree retains only untracked files unrelated to this remediation: `1113.json`, `1115.json`
- This round's closing check corrected 3 document-vs-reality inconsistencies: supplementary test entry count 11→16, commit status update, §2 memory basis reworded to "single-point measurement + derivation"

---

## Gate 3: Implementation Record (2026-11-15, based on frozen design e0c3cf1)

### What Changed

| File | Content |
|---|---|
| `kong/plugins/rate-limit-advanced/lib/lease.lua` | ① Pool lifecycle: `active` set + `last_used` (assigned once at TAKE) + `max_age` millisecond snapshot (taken at first GRANT as `bucket_ttl_ms`=2×window); diagnostic list `pool.leases` abolished, history moved to counters. ② Counter extensions: `expired/evicted/discarded_tokens`; `stats()` outputs `outstanding/pools`. ③ Expiry: `created_at + max_age/1000 < ngx.now()` ⇒ EXPIRED, removed via the single function `expire_lease_at` (state flip → count → removal from active, within the same non-yield section); TAKE performs a per-candidate O(1) expiry comparison. ④ Single in-flight GRANT: `_inflight[pool_key]` flag (set/cleared within grant with no yield gap); register rejects Pools with non-empty ACTIVE (`pool has active lease` ⇒ unreachable in production; if triggered, classified as uncertain loss). ⑤ Capacity: `MAX_POOLS=10000` (module constant, overridable by tests), `ensure_capacity()` (at cap, first evict empty pools ≤64; still full ⇒ false), `evict_idle_pools` (deletes only Pools without ACTIVE Leases, zero inventory loss), `timer_sweep_once` (idle-candidate determination + expired removal + pool deletion, ≤64/tick), `start_sweep_timer` (`ngx.timer.every(60,…)`, module-level dedup, pcall, exiting check; safely skipped in resty environments without timers). ⑥ `invariants()` extensions: per-Pool `#active ≤ 1`; global identity `tokens_granted == tokens_consumed + Σactive.remaining + discarded_tokens`; lease count closure `leases == closed + expired + active`. |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | `check_lease` inserts two degraded categories after NEED_GRANT (frozen Plan B): `ensure_capacity()` false ⇒ `pool_cap`; `grant_in_flight(key)` true ⇒ `inflight`. Both degrade to `redis_mod.grant(conf, key, 1, …)` direct grant (no registration, reuses the batch=1 existing 429/Fail-close semantics, excluded from the Lease ledger); logs `pool_cap_degraded` (warn, rare) / `inflight_degraded` (debug). |
| `kong/plugins/rate-limit-advanced/handler.lua` | `init_worker` calls `lease.start_sweep_timer()`; on failure logs warn (measured in container: no alert, Workers register normally). |
| `test/lease-unit.lua` | 45 assertions (was 25, intents preserved): diagnostic-list assertions changed to counter closure; "multiple Leases coexisting" changed to sequential epochs + busy rejection; new expiry (including counted-once discarded / millisecond unit conversion), sweep_pool, Timer (idle pools deleted / active retained / cap 64 / 70 pools over two rounds), MAX_POOLS (including "pools with ACTIVE Leases not evicted"). |
| `test/algorithm-lease-unit.lua` | 25 assertions (was 17): block-D converted to counter closure; new K (pool_cap degraded direct grant + restored after empty-pool eviction), L (inflight degraded direct grant + excluded from ledger), M (N=20 coroutine burst: transport exactly once, direct 19 times, `#active==1`, identity holds). |
| `test/lease-iso.lua` | lease_id output now taken from `pool.active` (diagnostic list abolished), isolation assertions unchanged. |
| `test/lease-concurrent-grant-probe.lua` | Added `redis_mod.grant` stub counting (direct-grant degradation is now a real path); output adds `direct_calls` and a `leases<=1` verdict. |

**Frozen-item check**: MAX_POOLS=10000 ✓; max_age=2×window millisecond snapshot ✓ (`created_at + max_age/1000 < ngx.now()` second scale) ✓; 60s Timer ✓; Plan B ✓; no eviction of ACTIVE Pools at cap ✓; EXPIRED remaining counted into discarded, never returned to Redis ✓; ledger `confirmed_granted = consumed + outstanding + discarded`, uncertain tracked separately and never mixed in ✓. **Not implemented**: §1's `sweep_seq` field — replaced by the disjoint-set argument "Timer touches only idle Pools, request path touches only the current Pool", leaving no duplicate-reclamation window (the field was found to have no active role, a design redundancy; can be added later if needed).

### Test Commands and Real Results (all measured this round)

| Command | Result |
|---|---|
| `bash test/lease-unit.sh` | **PASS 45 / FAIL 0** (including new expiry/Timer/capacity/bound/ledger cases) |
| `bash test/algorithm-lease-unit.sh` | **PASS 25 / FAIL 0** (including new cases K/L/M) |
| `bash test/config-isolation-unit.sh` | PASS 15 / FAIL 0 |
| `bash test/evalsha-unit.sh` | PASS 8 / FAIL 0 |
| `bash test/lease-grant-smoke.sh` | PASS 4+7 / FAIL 0 |
| `bash test/lease-isolation.sh` | PASS 7 / FAIL 0 |
| `bash test/lease-redis-matrix.sh` | PASS 50 / FAIL 0 |
| `bash test/concurrent-lease-e2e.sh` (real OpenResty multi-Worker) | **PASS 17 / FAIL 0 / NOT_VERIFIED 0** (GRANT=10, Σgranted=100, no pile-up at 270 concurrent ⇒ degraded path not triggered, behavior identical to baseline) |
| `bash test/lease-exhaustion-e2e.sh` | PASS 11 / FAIL 0 |
| `bash test/config-isolation-e2e.sh` | PASS 14 / FAIL 0 |
| `bash test/algorithm-lease-e2e.sh` | PASS 15 / FAIL 0 |
| `bash test/fault-recovery-e2e.sh` | PASS 12–14 / FAIL 0 (assertion count fluctuates with recovery polling timing; two retests 14; not a degradation) |
| `bash test/handler-fault-e2e.sh` | PASS 26 / FAIL 0 |
| `bash test/lease-timeout-uncertain-e2e.sh` | PASS 22 / FAIL 0 / NOT_VERIFIED 0 |
| `bash test/script-cache-selfheal-e2e.sh` | PASS 15 / FAIL 0 |
| `bash test/worker-crash-e2e.sh` | PASS 16 / FAIL 0 |
| `docker compose exec -T kong1 resty /tmp/lease-concurrent-grant-probe.lua` (coroutine model) | Post-fix: burst N=100 ⇒ transport=1, direct=99, `leases=1(<=1:true)`, outstanding=9 (pre-fix: leases=100, outstanding=900); steady likewise `leases≤1`; all identity_ok=true. **Real OpenResty concurrency verification NOT VERIFIED (maintained)** |
| `docker compose exec -T kong1 resty /tmp/lease-memory-baseline.lua` | Post-fix: **600 B/pool (was 689 pre-fix, down after diagnostic list removal)**; recoverable to ~1.3MB after GC; invariants=true; MAX_POOLS estimate updated: 10000×600B ≈ **5.9 MB/Worker** |
| `docker compose exec -T kong1 kong reload` + traffic verification | New Worker (init_worker log handler.lua:20) serves normally, 200 + normal rate-limit headers; no `sweep timer not started`/`timer create failed` alerts |

### Ledger / Bound / Concurrency Verification Evidence (conventions kept distinct)

- **Ledger identity**: lease-unit (accounting-identity, expire-discarded-once, expire-invariants, capacity-invariants) + algorithm-lease-unit (M-ledger-identity, L-direct-out-of-ledger) + all probe scenarios identity_ok=true + invariants() global checks. Uncertain excluded from the identity: the existing grant-uncertain-no-retry-no-register assertion is preserved and PASSes.
- **active bound**: register busy rejection (multi-lease-busy-reject) + invariants() `#active ≤ 1` check + case M burst N=20 asserting `st.active == 1` + probe burst N=100 `leases=1(<=1:true)`.
- **Concurrent GRANT (real environment vs model)**: real OpenResty evidence = concurrent-lease-e2e.sh (270 concurrent, GRANT=10 no pile-up, degraded path not triggered — consistent with baseline) + worker-crash/timeout etc. E2Es all green; coroutine-model evidence = probes and case M (quantified degradation effect: inventory 900→9). **The latter must not be written up as real-concurrency verification (NOT VERIFIED maintained)**.

### External Behavior Impact

- Normal path (no concurrent pile-up, Pool below cap): **byte-for-byte identical to baseline** (the 10 green E2Es such as concurrent-lease-e2e are the evidence); 429/Retry-After/X-RateLimit-*/503 Fail-close/fault_tolerant/batch=1/multi-rule all-or-nothing semantics untouched.
- New behavior 1: concurrent misses while the same Pool has an in-flight GRANT ⇒ batch=1 direct-grant allowance (authorization still decided by the Redis bucket; empty bucket still 429; Redis failure still 503/fail-open). Throughput: hot path unchanged; direct path is one Redis call per request (same cost as batch=1).
- New behavior 2: MAX_POOLS at cap with no evictable empty pool ⇒ direct grant as above (rare, high-cardinality attack scenarios only); empty-pool eviction has zero inventory loss and produces no 429/503.
- New behavior 3: expired Leases are discarded at TAKE (discarded count) — no more bucket-epoch-crossing consumption on slow hot Pools; under clock rollback inventory lives slightly longer (§3 existing qualification, direction conservative).
- Semantic risk point (assessed): register busy rejection classifies requests as uncertain when the "bound is broken" ⇒ Fail-close (conservative direction, cannot masquerade as allowance).

### Open Questions / Risks

- **Real OpenResty concurrency verification NOT VERIFIED (maintained)**: coroutine-model and real-E2E dual evidence has been maximally strengthened, but there is no field data for "the trigger rate of the degraded path under real cosocket interleaving" (the concurrent-lease-e2e scenario did not trigger it). A dedicated E2E with CLIENT PAUSE + concurrent load could re-verify (pending authorization).
- **Worker RSS (Layer 2) / long-duration soak (Layer 3) NOT RUN (maintained)**; post-fix Lua heap measured at 600 B/pool.
- **Field observation of the Timer's periodic firing NOT VERIFIED**: registration without error + callback-body logic covered by timer_sweep_once unit tests; the 60s field firing (including the worker exiting branch) not directly observed.
- `sweep_seq` not implemented (see above: design redundancy, no behavioral impact).
- N3 (Cluster CROSSSLOT) **remains unauthorized**; N1/N2 (dimension value collisions) untouched (key shape change needs confirmation); N4–N8 remain recorded.
- Probe steady scenario grant_calls=8/direct=29: there is still no means of cross-path reconciliation between the Lease ledger and direct grants (V1 has no Redis reconciliation interface); the "loss allowed, direction conservative" statement is maintained.

### Gate 3 Review Fix: Capacity Boundary (inflight Pool reclamation exclusion + in-flight GRANT seat holding)

**What changed / why**: review found that `evict_idle_pools()` and `timer_sweep_once()` check only that `active` is empty, without excluding Pools with in-flight GRANTs — a Pool could be reclaimed while its GRANT is yielding, and `register()` would then rebuild it after return ⇒ `_pool_count` could exceed MAX_POOLS. Fix (`lib/lease.lua`): ① both reclamation paths skip Pools with `_inflight[key]==true`; ② reasoning surfaced a same-family issue — cross-Pool concurrent GRANTs each pass ensure_capacity before register, also exceeding the cap ⇒ `ensure_capacity()` changed to the convention that in-flight GRANTs **hold pool seats**: capacity is deemed reached when `_pool_count + inflight_count() ≥ MAX` (the frozen behaviors "no eviction of ACTIVE Pools / no 429 / no 503" are unchanged; only the degradation determination now covers in-flight seat holding); ③ `invariants()` gains the capacity-cap invariant `_pool_count ≤ MAX_POOLS` (except in tests that directly modify MAX into artificial states — the existing capacity cases restore MAX before asserting, no change needed).

**Test commands and real results** (all measured):
- `bash test/lease-unit.sh` → **PASS 50 / FAIL 0** (4 new cases: timer-skip-inflight, timer-evict-after-inflight-clear, evict-skip-inflight, evict-after-inflight-clear)
- `bash test/algorithm-lease-unit.sh` → **PASS 32 / FAIL 0** (new case N: deterministic coroutines — while A's GRANT is yielding, B triggers capacity reclamation; asserts A's Pool object is not reclaimed/rebuilt (same table reference), empty pool C is evicted normally, B degrades to direct grant, after recovery `pool_count ≤ MAX_POOLS`, identity holds)
- `bash test/concurrent-lease-e2e.sh` ×3 → **PASS 18 / FAIL 0 / NOT_VERIFIED 0** ×3. Assertion adaptation (Plan B designed behavior, not degradation): the original `allowed == Σgranted(Lease)` no longer holds when direct-grant degradation triggers; changed to **total authorization ledger = Lease Σgranted + direct grants == limit=100**, with the direct-grant batch evidenced by the EVALSHA delta in Redis `INFO commandstats` (delta − Lease record count − denied-GRANT count). Round 1 real-environment measurement: Σgranted=96 + direct=4 = 100 allowed, ledger closes exactly — **the degraded path triggered in the real OpenResty environment and was verified with a closed ledger** (the coroutine model's quantified conclusions maintain the NOT VERIFIED convention unchanged).
- `docker compose exec -T kong1 resty /tmp/lease-memory-baseline.lua` → PASS (invariants include the new capacity invariant; probe matches directly built scale via `lease.MAX_POOLS = N`)
- `bash test/algorithm-lease-e2e.sh` PASS 15/0; `bash test/worker-crash-e2e.sh` PASS 16/0; `bash test/lease-exhaustion-e2e.sh` PASS 11/0; `bash test/config-isolation-unit.sh` PASS 15/0; `bash test/lease-grant-smoke.sh` PASS 7/0; `bash test/evalsha-unit.sh` PASS 8/0.

**External behavior impact**: only the capacity determination convention tightened (in-flight GRANT seat holding) — normal traffic (Pool count ≪ 10000) is byte-for-byte unchanged; under high-cardinality attack the degradation determination is more conservative (degrades to direct grant earlier within the in-flight window), still no 429/no 503.

**Open Questions**:
- `config-isolation-e2e.sh` has a **pre-existing flake unrelated to this fix** ("B bucket key ≠ A bucket key" occasionally sees the same fingerprint under config propagation timing; historical report PHASE8_B recorded a similar flake). 5 rounds this round: 3×14/0, 2×13/1 (flake rounds), re-runs restore all green; the script was not modified.
- The Redis-side count for the direct-grant batch is derived only for this E2E from commandstats (delta − records − denied); there is no such reconciliation convention in normal runtime (the V1 "no reconciliation interface" statement is maintained).

### Gate 3 Re-Review Fix: Capacity Counting Deduplication (in-flight GRANT holds seats only for new Pool Keys)

**What changed / why**: re-review found `ensure_capacity()` uses `_pool_count + inflight_count()` to judge capacity, but in-flight GRANTs on Pools already present in `_pools` are counted twice (register reuses the original pool, creating nothing) ⇒ unnecessary capacity degradation. Fix (`lib/lease.lua`): `inflight_count()` counts only in-flight keys where `_pools[key] == nil` (only keys that would create a new pool hold seats). The inflight-skip protection in both reclamation paths is unchanged; the `invariants()` `pool_count ≤ MAX_POOLS` invariant is unchanged.

**Test commands and real results** (all measured):
- `bash test/algorithm-lease-unit.sh` → **PASS 36 / FAIL 0**. Case N updated to the fixed semantics: while A GRANTs (yielding) on an **existing Pool**, B should normally GRANT using the last remaining pool seat (`calls.grant==0`, no degradation log, B's pool created, count=2=MAX); after A recovers, register reuses the original Pool (same table reference), total ≤ MAX, identity holds (the deterministic test for re-review requirement 3). New case O: two **new Pool Keys** GRANT concurrently holding two seats, a third new Key correctly degrades to direct grant (`calls.grant==1`, warn=1), and after both in-flight registrations `pool_count == 2 ≤ MAX` (verification requirement 4).
- `bash test/lease-unit.sh` → PASS 50 / FAIL 0; memory probe PASS (includes the capacity invariant); concurrency probe burst N=100: `leases=1`, inventory 9 (invariant holds).
- Full regression of 14 entry points: matrix 50/0, concurrent-lease-e2e **18/0**, exhaustion 11/0, algorithm-e2e 15/0, fault-recovery 13/0, handler-fault 26/0, timeout-uncertain 22/0, selfheal 15/0, worker-crash 16/0, isolation 7/0, smoke 7/0, evalsha 8/0, config-isolation-unit 15/0.
- `config-isolation-e2e`: the regression run showed a raised flake rate, traced to a **pre-existing test non-determinism defect** — B_BKT sampling uses unordered `SCAN | head -1`, which may sample A's key when A/B bucket keys coexist (the same round's "B pool_key ≠ A pool_key" PASS proves B's record is correct). Minimal fix (explicitly exclude A_BKT before sampling; assertion intent unchanged), after which **4 consecutive runs 14/0**. Not a production-code issue, unrelated to the capacity fix.

**External behavior impact**: eliminates spurious degradation — an existing Pool already in flight is no longer double-counted in capacity ⇒ under high cardinality "the last pool seat" can be used normally; in-flight new Pools still hold seats ⇒ `_pool_count ≤ MAX_POOLS` remains strictly true. Frozen behaviors (no eviction of ACTIVE Pools, no 429/no 503, Plan B) unchanged.

---

## Gate 4: Unified Key Construction (Task A, based on ce78bd9)

### Task A: Unified Key Construction (dimension collisions + CROSSSLOT, implemented in one pass)

**What changed / why**:
- Added `lib/keys.lua`: `encode_value(s)` — dimension values escape only 4 ambiguous bytes (`:`→`%3A`, `%`→`%25`, `{`→`%7B`, `}`→`%7D`; all other bytes, including non-ASCII, pass through unchanged; Redis keys are binary-safe; fast path returns unchanged when no ambiguous bytes, zero hot-path overhead); `build_lease_key(bucket_key, lease_id)` — appends `:lease:<lease_id>` after the bucket key, sharing the same hash tag with the bucket key ⇒ same Cluster slot (eliminates the key-layer root cause of CROSSSLOT). lease_id input spec: non-empty and must not contain `{`/`}`/`%` (if present, reject → existing failure branch Fail-close, zero writes; this check is an input spec; `:` segments in lease_id under the same input spec may pass through unchanged).
- `lib/algorithm.lua`: dimension values in `build_key`/`build_group_keys` pass through `encode_value`; bucket key construction is **not relocated** (continues using `build_key`/`build_group_keys`, avoiding unrelated refactoring); the policy fingerprint is **unchanged** (fingerprint inputs exclude dimension values/encoding).
- `lib/redis.lua`: `grant_lease()`'s lkey is now built by `build_lease_key` (call-site code; embedded script strings untouched).
- **KEYS order check (GRANT vs RETURN)**: GRANT_LEASE = `KEYS[1] bucket key / KEYS[2] Lease key` (`redis/grant_lease.lua:19-20,34-35`); RETURN_LEASE = `KEYS[1] Lease key / KEYS[2] bucket key` (`redis/return_lease.lua:11-12,24-25`) — **the two paths have opposite KEYS order**; the construction rule is unified as `build_lease_key(bucket key, lease_id)`, with arguments passed per each script's KEYS order. This gate changes no Lua script (including `redis/*.lua`, the embedded scripts in `lib/redis.lua`, and their comments); the old key format descriptions in script header comments are outdated, belong to the script-freeze scope, and will be handled at a later protocol gate (recorded in Open Questions).
- Test synchronization (same commit): SCAN patterns in 9 E2Es changed from `'kong:rl:lease:*'` → `'kong:rl:*:lease:*'` (worker-crash, algorithm-lease-e2e, concurrent, config-isolation, fault-recovery, handler-fault, lease-exhaustion, lease-timeout-uncertain); 96 literal occurrences in `lease-redis-matrix.sh` changed from `kong:rl:lease:<id>` → `kong:rl:{p3g:m}:lease:<id>`; `lease-grant-smoke.lua`'s keys pattern and lkey construction changed to bucket-key derivation; `config-isolation-unit.lua` gains 8 new key assertions (CRC16-XMODEM known vector 0x31C3 self-check, `:{}%` escaping, stability for the same input, no collisions across dimensions, hash tag structure `{}` only at skeleton boundaries, Lease/bucket key slot equality (equivalent algorithm), lease_id input spec); `concurrent-lease-e2e.sh`'s final tokens sampling excludes `:lease:` keys, plus two lesson-driven fixes for SIGPIPE/mixed period (see below).
- `docs/architecture.md` §5 key-format line synchronized (dimension encoding + Lease key same tag + old format deprecated).

**Compatibility (expanded per review requirements, including Correction 2's window split)**:
1. **Rolling-upgrade coexistence (cannot be simplified as "one-time extra grants")**: while new and old version Workers run simultaneously, the two key sets keep separate ledgers — the same logical dimension instance simultaneously holds the **old bucket (existing level) and the new bucket (fresh full initial quota)**, so the actual allowance cap = sum of both ⇒ **total grants may exceed a single version's quota** (worst case 2×). A new key regains a fresh full initial quota on first use, and so does every new dimension instance (new ip/header/path values).
   **The two TTL types must be separated (Correction 2)**:
   - **Old bucket TTL (2×window)**: determines when the **old bucket's rate-limit authorization state (tokens/ts) disappears** — i.e., the convergence time of the allowance-cap stacking window; during the window old and new buckets coexist and total grants may exceed a single version's quota; after the window the old bucket keys expire naturally and only new buckets keep the ledger.
   - **Old Lease metadata 1h TTL**: determines **only** when the metadata record (for reconciliation/forensics) is cleaned up; unrelated to inventory return (V1 has no RETURN), **does not represent convergence of the rate-limit authorization state** — authorization state is carried by bucket keys and is unaffected by this TTL.
2. Old keys are not reused; the fingerprint is unchanged (same policy has the same fingerprint segment, only value encoding differs ⇒ old buckets cannot be hit by new code).
3. Old-format Lease records disappear naturally via the 1h TTL; the new SCAN pattern does not match the old format (test environment is a fresh key space, no mixing).

**Test commands and real results** (all measured):
- Unit: `config-isolation-unit.sh` **24/0** (including 8 new key assertions); `lease-unit.sh` 50/0; `algorithm-lease-unit.sh` 36/0; `evalsha-unit.sh` 8/0.
- Bare-Redis: `lease-redis-matrix.sh` **50/0** (all literal references updated to the new format; the full GRANT/RETURN matrix runs over the new key format).
- Real Redis path: `lease-grant-smoke.sh` 4+7/0 (new-format record forensics).
- E2E (real OpenResty multi-Worker, new key format live): concurrent-lease **19/0 ×3** (Σgranted=92+8, 93+7, 97+3, 98+2 all close exactly on 100; direct-grant batch 2~9 fluctuates with timing); exhaustion 11/0; config-isolation 14/0; algorithm-e2e 15/0; fault-recovery 12–14/0 (polling fluctuation); handler-fault 26/0; timeout-uncertain 22/0/0; selfheal 15/0; worker-crash 16/0; isolation 7/0.
- Incidental test-script fixes this round (same commit, not out of scope): ① `concurrent-lease-e2e.sh` adds a "reload mixed-period convergence wait" up front (lesson: after `kong reload`, old Workers coexist briefly; old-format records are not counted by the new SCAN but are counted by EVALSHA ⇒ a spurious ledger delta); ② assertion 8's `SCAN|head` SIGPIPE lesson fix (silent interruption under pipefail) + tokens sampling excludes `:lease:` keys (new Lease keys share the bucket key prefix; otherwise the assertion passes vacuously; this round's measurement tokens=0.0011881189776839 was non-empty).

**NOT VERIFIED (declared as-is)**: GRANT_LEASE/RETURN_LEASE/EVALSHA/NOSCRIPT behavior under a real Redis Cluster environment is unverified (this environment is standalone; `CLUSTER KEYSLOT` returns cluster support disabled); slot equality is verified by the test-side CRC16-XMODEM equivalent algorithm. **Fixing CROSSSLOT does not equal full Redis Cluster support** — Cluster deployments still require independent verification of per-node script caching, redirection, etc. (existing Deferred record maintained).

**Open Questions**: ① the old key format descriptions in `redis/grant_lease.lua:20`, `redis/return_lease.lua:11`, and the embedded script headers of `lib/redis.lua` are not updated (script files are frozen in this gate, deferred to the protocol gate); ② N1 (dimension value 256-char truncation collision) is outside this task's scope, kept on record; ③ full percent encoding (non-ASCII bytes passed through) is this gate's decision; if full-ASCII keys are ever required it can be re-evaluated (which would change all keys again).

### Task A Review Corrections (2026-11-15, two items, no scope expansion)

**Correction 1: wait_stable() reliability**. The original implementation `pgrep -f 'nginx: worker process'` could falsely match the shell executing the command (its cmdline contains that pattern string), and "process count identical twice in a row" cannot prove old Workers exited (with 2 old + 2 new, the count stays 4). Rewrite (test/concurrent-lease-e2e.sh):
- Enumeration: **prefix** exact match of `/proc/[0-9]*/cmdline` against `"nginx: worker process "` (the shell's own cmdline starts with `sh -c` ⇒ no match; head/tr child processes likewise) ⇒ outputs the set of Worker PIDs.
- Generation determination: the old-generation PID set is captured **before** config push (POST /config may trigger a reload); convergence = single generation — no reload (current set == old-generation set) or all old-generation PIDs exited (the two sets are disjoint); if either cannot be proven ⇒ 30s timeout fails the run with "cannot prove all old Workers exited", without weakening the ledger assertion's evidence strength.
- Function definition moved before the PID snapshot (the original order had a use-before-definition defect, fixed this round).
- Conclusion wording converged to "Worker generation is single (PID set evidence: no reload same set, or all old-generation PIDs exited)", claiming nothing beyond the evidence.
**Verification**: `bash -n` syntax passes; `bash test/concurrent-lease-e2e.sh` ×3 → **EXIT=0, PASS 20 / FAIL 0 / NOT_VERIFIED 0 ×3** (rounds 2/3 totals 90+10=100, 97+3=100 close exactly; existing assertions untouched; the PASS count 19→20 is because the generation determination itself adds 1 new ok()).

**Correction 2: compatibility window split**. The original wording "window = max(old bucket TTL, old Lease record 1h)" conflated two TTL types: the old Lease metadata's 1h TTL determines only the **reconciliation record cleanup time**, is unrelated to inventory return (V1 has no RETURN), and does not represent convergence of the rate-limit authorization state; authorization state is carried by bucket keys. Changed to two independent statements: old bucket TTL (2×window) = convergence time of the allowance-cap stacking window; old Lease 1h TTL = metadata record visibility window. Documentation-only change.

### Task A Re-Review Closing Corrections (2026-11-15, two items, test/concurrent-lease-e2e.sh only)

**What changed / why**:
1. **Old-generation PID snapshot validity verification (new, before config push)**. The original implementation captured `PIDS_K1/K2/K3` and went straight to `wait_stable()` → `single_generation()`: an empty snapshot would misjudge "old generation empty" as "old generation all exited" (`single_generation` returns 0 for empty `$1`), weakening the ledger assertion's evidence strength. Correction: a pre-check loop records each node's Worker count (`W_K1/K2/K3`), and after the snapshot is captured each node is verified — **non-empty, `wc -w` ≥2, and consistent with the pre-check count**; if any fails ⇒ `bad` + `exit 1` immediately, no empty set may enter the generation determination; on success outputs `ok "snapshot valid: …"` (1 PASS per node).
2. **Removed the duplicate "config pushed" ok()**. After successful config push, the same ok() was output twice in a row (no new information), inflating the PASS count by 1. One instance removed, keeping the PASS count accurate.

**Test commands and real results** (measured this round):
- `bash -n test/concurrent-lease-e2e.sh` → syntax passes.
- `bash test/concurrent-lease-e2e.sh` ×2 → **EXIT=0, PASS 22 / FAIL 0 / NOT_VERIFIED 0 ×2** (round 1: Σgranted=92+direct 8=100, 429=300, min remaining=0; round 2: Σgranted=95+direct 5=100, 429=300, min remaining=0). PASS count 20→22 is from 3 new ok() for snapshot validity verification minus 1 duplicate ok() (20+3−1=22).

**External behavior impact**: none (test script only; production code, frozen design, and existing assertions untouched).

**Open Questions**: none new; existing items maintained (script header comment's old key format description, N1, real Cluster verification Deferred).

---

## Gate 4: Task B — Lease Metadata Cost Audit (based on a2ba601, 2026-11-15, read-only)

**What changed**: no production code/script/Schema changes. Only this section added (committed as an independent documentation commit). Test environment writes (synthetic records) were all cleaned via UNLINK; DBSIZE restored to 137, used_memory restored to 1.71M.

### Audit Conclusion 1: Lease Hash Fields and Per-Record Cost (measured)

- **Fields (5, HLEN measured=5)**: `lease_id` (host:worker:seq:hex, 26~27B), `pool_key` (bucket key verbatim, 43B), `granted` (numeric string), `status` (`OPEN`), `created_at` (server-side Redis TIME floating-point string, 16B). After RETURN, `return_requested` is appended (6 fields). All are hash string fields (`redis.lua:274-280`; dual source `redis/grant_lease.lua:131-137` same origin, same shape).
- **TTL (measured)**: PTTL=3,592,908ms (≈59.9min) ⇒ 1h effective. `LEASE_TTL_MS=3600000` is a fixed constant (`algorithm.lua:21`, not a Schema field, no configuration override); the script sets it via `PEXPIRE lkey` (`redis.lua:280`).
- **Expiry behavior (frozen convention restated)**: at TTL expiry the whole key is deleted — **only the metadata disappears**; no token restoration, no inventory return (V1 has no RETURN; do not describe metadata expiry as inventory return). RETURNED records are retained until the **original TTL** (not reset, `redis.lua:398`) = idempotency protection window ≤1h.
- **Single-key memory (measured)**: a real record (74B key) MEMORY USAGE=280B; an equal-length synthetic key (75B) SAMPLES 0=280B; a short key (48B) at 1M scale=264B ⇒ key length +27B payload ≈ +16B memory.

### Audit Conclusion 2: GRANT_LEASE Write Commands and Round Trips (conventions kept distinct, never conflated)

| Convention | granted≥1 (record created) | granted=0 (insufficient) |
|---|---|---|
| Write commands inside the script | **4** (bucket HSET+PEXPIRE, record HSET+PEXPIRE) | 2 (bucket only; no record) |
| Of which for the record itself | 2 (HSET 5 fields + PEXPIRE) | 0 |
| Network round trip | **1** (EVALSHA; keepalive connection reuse; no LOAD after script caching) | 1 |

- First use per Worker per script adds +1 SCRIPT LOAD round trip; NOSCRIPT at runtime ⇒ +1 LOAD +1 EVALSHA retry exactly once (frozen semantics unchanged, `redis.lua:444-463`). Corroboration: concurrent-lease-e2e Gate 4 commandstats-convention measurement (400 requests / EVALSHA delta 318, including denied-GRANT and the direct-grant batch).

### Audit Conclusion 3: RETURN_LEASE (code verification; V1 has no production call site)

- `lib/redis.lua` has no `_M.return_lease` wrapper function; the script is only registered (`redis.lua:422`) and production code never calls it — consistent with the Gate 1 lead e conclusion; the only execution entry point is the test (`lease-redis-matrix.sh` bare --eval).
- **Write commands**: idempotent commit point `HSET lkey status=RETURNED + return_requested` (1) → when requested>0, + bucket HSET+PEXPIRE (3 total); TTL **not reset**.
- **Idempotency (per the script's actual logic)**: `ALREADY_RETURNED` (status=RETURNED and return_requested==requested, zero writes); `RETURN_CONFLICT` (same status, different requested, zero writes); `POOL_MISMATCH`/`LEASE_NOT_FOUND` and other check failures all write nothing.

### Audit Conclusion 4: Memory Cost Quantification (10k / 100k / 1M)

**Test environment**: docker compose redis (Redis 7.4.12, standalone, no persistence, no maxmemory/noeviction), host with 15GB; synthetic records structurally identical to real records (5 fields with equal-length values, PEXPIRE 3600000); loaded via `redis-cli --pipe` (1M records 10.2s, errors=0).

| Scale | used_memory delta (measured) | Average B/record (measured, 48B keys) | Total memory (with key-length correction, estimated) |
|---|---|---|---|
| 10k | 3,162,736B (3.16MB) | 316 | ≈3.3–3.5MB |
| 100k | +27,755,024B ⇒ cumulative ≈30.9MB | 308 (marginal) | ≈32–34MB |
| 1M | +288,280,064B; used_memory_human=**306.08MB** | 320 (marginal) | ≈**330–350MB** |

- **Convention notes**: batch average (308~320B/record) = single-key intrinsic memory + keyspace dict and expire table amortized overhead; single-key intrinsic memory (measured 264B@48B key / 280B@74B key) excludes keyspace overhead — the four conventions (write command count / round trips / single-key memory / total memory) are never interchangeable.
- **Estimate basis (derived)**: measured baseline (48B key) + key-length correction +16~30B (real keys 70~80B: namespace varies, lease_id seq digits fluctuate).
- **Error sources**: ① key length and lease_id length fluctuate with deployment/timing (dominant, ±10%); ② dict rehash transients; ③ fragmentation (1M scale measured 1.03; small-scale noise up to 2.45); ④ allocator/Redis version differences.
- **NOT VERIFIED**: per-record structure under Redis Cluster is the same but per-node dict/expiry overhead, replication traffic, and the soak cost of TTL lazy/periodic deletion — all unverified.

**External behavior impact**: none (pure audit; no automatic RETURN wired in; Lease lifecycle, TTL, keys, and scripts unchanged).

**Open Questions**: ① Cluster memory/replication traffic unverified (existing Deferred record maintained); ② no new to-dos; no optimization proposed (nothing done without approval).

---

## Gate 4 Final Acceptance (based on 14297da, 2026-11-15, read-only audit)

**Conclusion: acceptance PASSED. No blocking issues.**

### 1. Implementation and Audit Record Completeness Check

- **Task A record**: main body (what changed/why/compatibility incl. window split/test commands and real results/NOT VERIFIED/Open Questions) + review corrections (Correction 1 wait_stable rewrite, Correction 2 TTL window split) + re-review closing corrections (PID snapshot validity verification, duplicate ok() removal) — all three segments complete, each with measured evidence and PASS-count conventions.
- **Task B record**: fields/TTL/single-key memory measurements, write commands and RTT convention separation, RETURN_LEASE code verification, 10k/100k/1M memory quantification (measured+derived+estimated layered labeling), NOT VERIFIED and error sources — complete.

### 2. Frozen Decision Compliance Check (full git diff ce78bd9..14297da checked)

- **No-touch files with zero changes**: `redis/*.lua`, `schema.lua`, `openspec/`, `bench/`, `docs/reports/` have diff file count = 0 within this gate's scope.
- **Embedded scripts untouched**: `lib/redis.lua`'s diff in this gate has only two hunks (`require keys_mod` + `_M.grant_lease` call-site lkey construction); GRANT_LEASE/RETURN_LEASE script string literals have zero changes (dual sources `redis/grant_lease.lua`, `redis/return_lease.lua` untouched).
- **Semantics-unchanged items check**: batch=1 per-request authorization, rules all-or-nothing, 429+Retry-After, X-RateLimit-* headers, Fail-close 503, fault_tolerant semantics, GRANT uncertainty no-retry no-registration, NOSCRIPT retry exactly once — this gate's diff touches none of these paths (changes limited to: `lib/keys.lua` added, `algorithm.lua` dimension values via encode_value, `redis.lua` call-site lkey, test synchronization, documentation).
- **No scope expansion**: RETURN wiring, N1, automatic lifecycle, Schema fields — none implemented (Task B explicitly proposes no optimization).

### 3. Test Results Summary (distinguishing PASS / FAIL / NOT RUN / NOT VERIFIED)

**Final HEAD (14297da) full re-test this round — measured, all PASS, 0 FAIL** (16 test entry points):

| Category | Script | Result |
|---|---|---|
| Unit | config-isolation-unit (incl. 8 key assertions) | 24/0 |
| Unit | lease-unit | 50/0 |
| Unit | algorithm-lease-unit | 36/0 |
| Unit | evalsha-unit | 8/0 |
| Bare-Redis | lease-redis-matrix | 50/0 |
| Smoke | lease-grant-smoke | 4+7/0 |
| E2E | concurrent-lease-e2e | 22/0 |
| E2E | algorithm-lease-e2e | 15/0 |
| E2E | lease-exhaustion-e2e | 11/0 |
| E2E | config-isolation-e2e | 14/0 |
| E2E | lease-timeout-uncertain-e2e | 22/0/0 |
| E2E | fault-recovery-e2e | 14/0 |
| E2E | handler-fault-e2e | 26/0 |
| E2E | script-cache-selfheal-e2e | 15/0 |
| E2E | worker-crash-e2e | 16/0 |
| E2E | lease-isolation | 7/0 |

Total **PASS=341 / FAIL=0 / NOT RUN=0**. NOT VERIFIED (not test items of this round; see §4).

### 4. Unresolved Risks and Deferred (which do not affect V1)

**Do not affect V1 (standalone deployment, under existing behavioral contracts)**:
- Full Redis Cluster support (the N3 key-layer CROSSSLOT is fixed, but per-node script caching/redirection/Cluster memory and replication traffic unverified) — standalone deployments unaffected; independent verification required before Cluster deployment (Deferred).
- Worker RSS / long-duration soak / real OpenResty concurrency verification (retained per Gate 2 freeze) — evidence-completeness gaps, not correctness blockers; ledger assertions already backed by E2E measurements.
- Outdated old key format descriptions in script header comments (`redis/grant_lease.lua:20`, `redis/return_lease.lua:11`) — documentary, no behavioral impact, deferred to the protocol gate.
- Task B memory estimate error ±10% — estimate fully labeled, not a risk item.
- Phase 5 lifecycle entirely DEFERRED (pre-existing project decision, outside V1 scope).

**Upgrade-window risks (one-time, do not affect steady state)**:
- Key migration compatibility window: during rolling upgrade, old and new buckets coexist ⇒ total grants may exceed a single version's quota (2×window TTL convergence); new dimension instances regain the initial quota — already described split per review requirements in Task A's compatibility section.

**Decisions deferred to later gates (not a blocker for this gate)**:
- N1 (dimension value 256-char truncation collision): kept on record; not implemented without approval.
- Full percent encoding decision: non-ASCII bytes passed through is this gate's decision; if full-ASCII keys are ever required, re-evaluate (which would change all keys again).

### 5. Git Status Check (measured)

- Branch `remediation/hardening`; HEAD=14297da5b60719bb63c07326b50eb0b34a734c25; in sync with `origin/remediation/hardening` (rev-list 0/0).
- Gate 4 commit chain (ce78bd9 → 14297da, 4 commits): `665fa8d` (Task A implementation) → `a43a20b` (review corrections 1+2) → `a2ba601` (re-review closing corrections) → `14297da` (Task B audit) — each step independent, scope progressive, no mixed commits.
- Working tree: tracked files with zero modifications; 3 untracked session export files (`1113.json`/`1115.json`/`1115-2.json`) are not repo content, not committed, not products of this gate.

**External behavior impact**: none (pure acceptance audit; the key format change's behavioral impact is recorded in Task A's compatibility section).

**Open Questions**: the §4 list is the complete set; no new blockers.

---

## Gate 5: Documentation and Algorithm Model Alignment (based on 80865dc, 2026-11-15, documentation only)

**What changed / why**: four documents aligned against the final code implementation; each committed separately; openspec/, docs/reports/, bench/, production code, Lua, and Schema have zero changes.

| Commit | File | Alignment Points |
|---|---|---|
| `e265f16` | docs/design.md | Cleared all ⟨TODO⟩; removed shared dict inventory descriptions (§2 overview diagram/sequence diagram, §5 fast path, §4.8, §7 fault matrix row); §4.9 adds Lease lifecycle and local Pool model (MAX_POOLS=10000/Worker, max_age=2×window, EXPIRED/EVICTED/discarded, 60s Timer, Plan B single in-flight, invariants() identity); §12 updates key structure (dimension value encoding + Lease key same hash tag) + Lease metadata model (5 fields, TTL 1h, not equal to inventory return) + Cluster support boundary (key layer fixed/behavior unverified); §7 fault matrix adds Pool-pressure degradation and metadata TTL rows; §8 experiment matrix marked Historical and pointed at Phase 7 measurements; §9 trade-offs table updated (Lease pre-authorization/dimension value encoding); §11 production gaps updated (local Pool reclamation implemented, RETURN still Deferred, clock conclusion); 【Historical】/【Current V1】/【Deferred】 labeling convention |
| `352fe1b` | README.md | Precision semantics rewritten as premise-qualified (grants ≤ confirmed debits derivation; under-grant with multiple sources listed factually; over-grant only in the fault rollback window); three risk categories added (fingerprint coexistence / primary rollback / local-consumption burst, with burst_max derived bound); §6 adds DB-less per-node push coexistence risk and mitigation advice; §8 performance figures completed (81.8%, Kong CPU −23%, Redis CPU −73%, all quoted only from Phase 7); stale assertion counts corrected (lease-unit 25→50, algorithm-lease-unit 17→36, concurrent-lease-e2e 17→22, Gate 4 acceptance measured values); comparison table's "only under-grant, never over-grant" rewritten as premise-qualified |
| `f6bf343` | docs/architecture.md | §1 architecture diagram redrawn (3 nodes × 2 Workers, per-Worker independent Lease pool, three request paths, Redis failure Fail-close, explicitly no cross-Worker inventory sharing); core invariants premise-qualified; §2 adds two degraded direct-grant paths (pool_cap/inflight); §3 decision flow adds degradation determination branches; §7 lifecycle diagram updated (EXPIRED/EVICTED/discarded, Timer, Plan B, O(1) bound); §8 ledger changed to the frozen identity confirmed_granted = consumed + outstanding + discarded (uncertain separate); §12 adds 81.8%; §13 Deferred table updated (local Pool reclamation implemented, Cluster key layer fixed) |
| `9d4e7ce` | docs/design.md | Trade-offs table consistency wording synchronized (derived bound / estimated / NOT VERIFIED layering) |

### Error Model Re-Derivation (core deliverable)

Variables unified: N=replica count, W=Workers per replica, W_total=N×W, k=batch, B=bucket capacity (burst>0?burst:limit).
The statistical object = the authorization inventory of a single logical key; scope and premises declared item by item:

- **Instantaneous hold ≤ W_total × k: derived bound** (premises: ① at any moment each Worker's each Pool has ≤1 active Lease —
  a Gate 3 invariant, guarded by invariants() assertions; ② granted ≤ k; ③ V1 has no RETURN). **Not the old N×W×k formula**:
  the old model assumed "one copy of inventory per node"; V1 Leases are Worker-private, so the bound scales with W_total.
- **No closed strict upper bound for per-window cumulative under-grant**: discarded (≤k per event; event count depends on traffic shape), Worker crash lost
  (≤k per event), GRANT uncertain (**no closed bound**: no-retry no-registration is frozen semantics; event count scales with fault rate) —
  all labeled "estimated", long-duration distribution NOT VERIFIED.
- Utilization table recomputed with W_total=6 (1000/k=20 → 88%; 100/k=2 → 88%; 10000/k=50 → 97%), labeled estimated.
- Burst amplification burst_max = B + W_total·k (derived bound); `resolve_batch` clamp(limit/50,1,50) matches the code;
  the "2%" semantics is clarified as **per-Worker** hold.

### Consistency Check (against actual code and frozen design)

- resolve_batch formula, MAX_POOLS, max_age=2×window, LEASE_TTL_MS=3600000, counted-once discarded,
  Plan B direct-grant degradation, key encoding (%3A/%7B/%7D/%25), 256 truncation (N1 kept on record), Phase 7 performance numbers
  (9.99:1 / 81.8% / −23% / −73% / p99 NOT VERIFIED / 7848=3.1%) — each verified consistent against code/reports.
- Both README occurrences of "shared dict" are negative "does not depend on" statements (accurate); design.md/architecture.md have no shared-dict
  inventory leftovers; cross-references among the three documents (§ numbers, report paths) checked.

### Test Commands and Real Results

- This gate is documentation alignment; no production code changes, no new/re-run tests; test status carried over from Gate 4 final acceptance
  (16 entry points PASS=341 / FAIL=0 / NOT RUN=0, measured at 14297da; this gate's baseline 80865dc differs from it by zero code changes).
- Scope verification (measured): `git diff 80865dc..HEAD --stat` touches only 4 documentation files;
  `git diff 80865dc..HEAD -- redis/ .../schema.lua openspec/ bench/ docs/reports/` file count = 0.
- Static checks (measured): `grep TODO docs/design.md`=0; mermaid diagram label pairing manually checked and passed;
  **mermaid rendering unverified** (no rendering tool in the environment, marked NOT VERIFIED).

### External Behavior Impact

None (documentation only; the behavioral contract wording changed from unconditional "no over-granting" to premise-qualified precision statements — descriptive alignment, not a behavior change).

### Residual Risks

① N1 (256 truncation cross-dimension collision) kept on record, unfixed; ② mermaid rendering unverified (manual check); ③ the W_total×k bound's
premises rely on invariants() assertion guarding rather than protocol guarantees (labeled factually in the text); ④ long-duration under-grant distribution
NOT VERIFIED maintained. No new blockers.

---

## Gate 5 Re-Review Corrections (based on 9d4e7ce→, 2026-11-15, four targeted items, no scope expansion)

**What changed / why** (each document committed separately; production code/Lua/Schema/openspec/docs/reports/bench untouched):

| Commit | File | Corrections |
|---|---|---|
| `5cfbb1d` | README.md | ① §9 "old Pool lifecycle reclamation not yet implemented" → **implemented** (Gate 2/3: MAX_POOLS, max_age=2×window, 60s Timer; automatic RETURN/Worker takeover/inventory compensation remain Deferred); ② §4 adds the limit=100, batch=10, 3-node×2-Worker quantified example: **60 tokens = derived upper bound of instantaneous hold, 60/100=60% = inventory exposure ratio (derived upper bound)**, explicitly labeled **not actual utilization, not a window-utilization lower bound**, actual hold far below the bound, with the Phase 7 measured exposure sample (7848/3.1%) for comparison |
| `035447c` | docs/design.md | ② §4.9 EXPIRED vs EVICTED distinction: **only EXPIRED's unconsumed inventory is counted into discarded**; EVICTED is a **Pool reclamation event (not a Lease state)**, evicting only empty pools without ACTIVE Leases, with **zero inventory loss and no discarded produced**; ③ adds "the three-layer distinction of invariants": the production code control path (single in-flight flag + non-yield sections) maintains the invariant → `_counters` bookkeeping updated in sync with state flips → **`invariants()` is a verification function actively called by tests, not a production runtime assertion** (not called on production paths); §4.3 premise wording synchronized |
| `02470aa` | docs/design.md | ② Supplement: §4.3 under-grant table row "Pool expiry (EXPIRED) discarded" and §11 quota reclamation entry wording synchronized |
| `893d432` | docs/architecture.md | ② Terminology convention row distinction (EXPIRED=the only state producing discarded; EVICTED=Pool reclamation event, zero inventory loss, not a Lease state); §7 lifecycle diagram notes and state machine description synchronized; ③ invariant layering explanation synchronized; Deferred table wording synchronized |

**Verification basis (code verification, measured)**:
- `lease.lua:491 invariants()` definition; grep across the repo finds call sites only in test/*.lua and probe scripts (lease-unit,
  algorithm-lease-unit, lease-grant-smoke, lease-memory-baseline); zero calls in `kong/` production code.
- Pool eviction in `lease.lua` deletes only pools with empty active (`evict_idle_pools`/`timer_sweep_once`/
  capacity-pressure eviction, `_counters.evicted` counts Pools); `expire_lease_at` is the
  sole source of `discarded_tokens` (`lease.lua:15,108-113`) ⇒ only EXPIRED produces discarded,
  EVICTED has zero inventory loss — consistent with the code.

**Test commands and real results**: documentation-only corrections, no production code changes, no new/re-run tests; test status carried over from Gate 4
acceptance (16 entry points PASS=341/FAIL=0). Scope verification: `git diff` for each commit touches only the corresponding document file.

**External behavior impact**: none (documentary corrections; the EXPIRED/EVICTED distinction was already consistent with actual code behavior — documentation alignment).

**Open Questions**: none new; existing items maintained (N1, mermaid rendering NOT VERIFIED, long-duration under-grant distribution NOT VERIFIED).

---

## Gate 5 Final Re-Review Corrections (based on 0405e4f, 2026-11-15, three targeted items, no scope expansion)

| Commit | File | Corrections |
|---|---|---|
| `e27c4fd` | README.md | ① Precision semantics block unified to the discarded convention: "Pool expiry (EXPIRED, the only state producing discarded) … EVICTED is merely an empty-Pool reclamation event with zero inventory loss" |
| `cdf6875` | docs/architecture.md | ① Terminology convention row's discarded definition unified with §1's under-grant source row (EXPIRED the only producer of discarded; EVICTED empty-Pool reclamation with zero inventory loss) — same convention as README |
| `67c7d7e` | docs/design.md | ② §4.3 premise-maintenance wording changed to "**maintained by the production code control path and state bookkeeping (single in-flight flag + non-yield sections + count synchronization), actively verified via invariants() in tests** (not called at production runtime)", no longer implying a production runtime assertion; ③ §4.3 table header "utilization lower bound (estimated)" → "**instantaneous inventory exposure ratio (derived upper bound)**" with recomputed values (12%/30%/12%/3%, = instantaneous hold bound/limit), with a convention note unified with README (not actual utilization, not a window-utilization lower bound); §4.4 reference wording synchronized |

**Verification basis**: all three items are convention/wording unification; the value conversion expresses the same derived upper bound in two forms (the original "utilization lower bound" =
1 − exposure ratio, now unified to the exposure ratio expression). EXPIRED/EVICTED semantics are consistent with the code (verified last round:
the sole source of discarded_tokens is expire_lease_at; eviction deletes only empty pools).

**Test commands and real results**: documentation only, no code changes, no new/re-run tests (Gate 4 acceptance status carried over).
Scope verification: each commit touches only the corresponding document file; openspec/, docs/reports/, bench/, production code, Lua, and Schema have zero changes.

**External behavior impact**: none.

**Open Questions**: none new; existing items maintained.

---

## Gate 6: Minor Engineering Issues (based on 9d02bcb, 2026-11-15, optional tasks handled item by item)

**Execution principle**: verify first (code / Kong 3.6 API / test entry points) before deciding; items with insufficient benefit or unverifiable status stay as-is with the reason recorded; each item committed independently.

### Task 1: consumer anonymous dimension — keep `anon` (no change), add documentation + guard test

- **Verification**: `kong.client.get_forwarded_ip()` exists in Kong 3.6 (already used by this plugin's ip dimension, `lib/algorithm.lua:75`); IP retrieval is feasible; but **trustworthiness depends on deployment-side `trusted_ips` configuration**, which is untrusted by default behind reverse proxies and cannot be guaranteed.
- **Decision: keep the `anon` behavior as-is**. Rationale: ① splitting by IP would turn consumer quota into a consumer×ip dual-dimension quota, inconsistent with consumer-dimension semantics; ② untrusted IPs would produce attacker-controlled key cardinality (the MAX_POOLS degradation can backstop but is not ideal); ③ those needing per-IP distinction for anonymous traffic should explicitly add `ip` to `limit_by` (an existing capability); ④ a changed dimension value ⇒ existing anonymous buckets cannot be hit (quota reset).
- **Delivery** (`b59f6e8`): `docs/CONFIGURATION.md` adds §3.1 "Dimension semantics: the consumer's anonymous fallback" (anonymous shared quota + reasons for no change); adds guard test `algorithm-lease-unit` A2 (asserting unauthenticated ⇒ `:consumer=anon}`), measured **37/0**.

### Task 2: redis.password — support vault references (referenceable) + E2E

- **Verification**: this plugin's schema already has `redis.password` (plain string), `lib/redis.lua` already supports AUTH (connect dual path); Kong 3.6 OSS official `kong.tools.redis.schema` defines password as `encrypted=true, referenceable=true, len_min=0` (verified inside the container); OSS supports secrets management (env vault `{vault://env/<resource>}` verified resolvable).
- **Delivery** (`50fc594`): schema aligned with official (`encrypted=true, referenceable=true, len_min=0`; DB-less has no database persistence, encrypted does not affect how this repo runs); new `test/redis-password-e2e.sh`: A. vault reference `{vault://env/kong-log-level}` resolved end-to-end + AUTH allowance 200; B. plaintext password allowance 200; C. wrong password ⇒ existing Fail-close 503. Measured ×2 **5/0**. The test includes an environment note: the schema is plugin code, **POST /config only rebuilds the iterator, not the Lua VM** ⇒ the test prefaces with `docker compose restart kong1` to load the new schema (written into the script with a comment).
- **Regression**: `config-isolation-e2e` 14/0, `algorithm-lease-unit` 37/0 (schema change with zero breakage).

### Task 3: Automatic dual-source script consistency check

- **Verification**: the four scripts' dual sources (redis/*.lua ↔ lib/redis.lua embedded literals) are currently **code-consistent** (differences are comments only: the file version has usage notes, the embedded version has review finding numbers); no existing automated check.
- **Delivery** (`5b4359d`): `test/script-consistency-check.sh` — extracts embedded literals, strips comments and blank lines, then line-by-line diff; does not change the runtime loading method (purely read-only check). Measured 4/0; negative verification: a changed code line is detectable (FAIL + diff output).

### Task 4: Repository housekeeping

- **Verification and disposition** (`db89f3d`):
  - `7arg`: debug leftover log in the multi-rule grant command, unreferenced ⇒ **deleted**.
  - `latency-summary.json`: single k6 output (11-12), referenced by no report, not the official Phase 7 data (Phase 7 raw data: 97 files in bench/raw/phase7/) ⇒ **deleted**.
  - `rule.md`: the project's original SDD document (Historical) ⇒ **moved to docs/archive/rule.md**; prose references inside the frozen openspec archive are historical records and left unchanged; non-frozen documents have no references needing correction.
  - `refresh.sh`: development helper (restart + FLUSHDB) ⇒ **moved to scripts/refresh.sh** (functionality kept; no references need correction).
  - `reports/` and `docs/reports/`: **not merged** — reports/ holds Phase 1–3 evidence whose paths are referenced by the frozen openspec archived change ("outputs reports/phase-1-correctness.md"); moving would break the frozen Spec; docs/reports/ holds Phase 6.3–8.2 reports. Explained in the docs/README.md index.
  - The two Phase 0 reviews: **not duplicates** — `docs/review-phase-0.md` (2026-11-11, Phase 0 audit, referenced by the openspec archive) and `docs/PHASE0_REVIEW.md` (2026-11-12, current-state review under the Phase 4 implementation spec) differ in content ⇒ **both retained**, noted in docs/README.md.
  - Untouched: `rl.json`, `Kong 3-Take home assignment.pdf` (untracked, not on this list), Phase 7 raw data, all official tests and frozen Specs.
  - **Added `docs/README.md`** documentation index (current/design/phase reports/archive categories, including the non-merging rationale).

### Task 5: CI (.github/workflows/ci.yml)

- **Verification**: real test entry points = 4 resty unit tests + matrix/smoke + 11 E2Es + quota.sh (needs k6); compose images already pinned (kong:3.6 / redis:7-alpine / hashicorp/http-echo:1.0).
- **Delivery** (`f48ba10`): covers ① Lua syntax check (luajit -bl, all 10 lua files measured passing); ② script consistency check; ③ 4 unit tests; ④ Redis integration (matrix + smoke); ⑤ full 11-item Kong E2E suite (serial, failure aggregation, no core tests skipped); ⑥ bench/quota.sh (installs pinned k6 v0.50.0 from the official GitHub release, not a mirror).
- **Tests not placed in CI, with reasons** (stated in workflow comments): bench/matrix.sh / k6 latency load tests (long-running, shared-Runner noise invalidates p99 attribution, Phase 7 requires a dedicated environment), soak (>24h), cross-machine RTT. The full performance matrix is not run (constraint 5).

### This Gate's Verification Summary (measured)

- New/changed tests: algorithm-lease-unit 37/0 (+A2), redis-password-e2e 5/0 ×2, script-consistency-check 4/0 (incl. negative verification), syntax check 10/10.
- Regression spot checks: lease-unit 50/0, config-isolation-unit 24/0, concurrent-lease-e2e 22/0, lease-grant-smoke 7/0, config-isolation-e2e 14/0.
- Scope verification: production code changed only in schema.lua (Task 2 authorized scope); core rate-limit semantics, Lua scripts, openspec/, docs/reports/, bench/raw/ untouched (git diff checked).
- CI workflow YAML syntax passes; the syntax check step was measured locally in the same environment (full CI run awaits the first push-triggered execution, NOT VERIFIED until first run).

### Incomplete Items (as-is)

- No "not done" items — all 5 tasks handled. Residual: ① CI's first real run unverified (awaiting push trigger); ② rotation of env vault references (TTL update mechanism) unverified (outside this gate's scope); ③ `refresh.sh` retained in scripts/ (FLUSHDB is destructive, dev environment only — constrained by the TESTING document convention at the script's location).

---

## Gate 6 CI First-Run Fixes (2026-11-15)

**First-run failure causes (runs 43708831517 / 43710394785, measured logs)**:
1. `test/script-consistency-check.sh` hardcoded temp files into `/tmp/opencode/` — a clean GitHub Runner
   lacks that directory, mktemp failed directly, and the consistency check could not start.
2. After the fix, round two (43710394785) failed only at `bench/quota.sh`: k6/quota.js uses ES2020 optional chaining (`?.`),
   unsupported by the bundled Babel in the CI-pinned k6 v0.50.0 (grafana/k6#2168;
   esbuild supports it from v0.52, default mode natively from v0.53 — official release notes).

**Fix commits**:
- `f4f3abc`: consistency check temp file management changed to `mktemp -d` creating an isolated temp directory + `trap EXIT` cleanup,
   no dependency on any pre-existing directory; local negative verification retained (changed code lines still detectable as FAIL).
- `9214eda`: CI's pinned k6 version v0.50.0 → **v0.57.0** (native `?.` support in ES6+ default mode;
   release asset existence verified; k6/quota.js not modified, no assertion lowering).

**Final run results (run 43711556576, ✓ test 2m8s, all steps actually executed, measured logs)**:
- Lua syntax check: all 10 lua files syntax ok (luajit -bl).
- Consistency check: 4/0 (mktemp -d path works on a clean Runner).
- 4 unit tests: lease-unit 50/0, algorithm-lease-unit 37/0, config-isolation-unit 24/0, evalsha-unit 8/0.
- Redis integration: matrix 50/0, smoke 4+7/0.
- All 11 E2Es PASS (failure aggregation prints each item): algorithm 15, exhaustion 11, config-isolation 14,
  timeout-uncertain 22, fault-recovery 12, handler-fault 26, selfheal 15, worker-crash 16,
  isolation 7, concurrent 22/0/0, redis-password 5.
- bench/quota.sh: allowed=100 / limited=350 / other=0 / total=450,
  **PASS: exactly equal to quota 100 (globally consistent)**, per-node 150-assertion check passed.
- No skipped tests, no lowered assertions; both failures were environment issues (temp directory / k6 version); the fixes touch no test logic.

**Residual**: none new (CI is green; the ubuntu-latest migration to Ubuntu 26 and the Node 20 deprecation notices are runner platform
hints, not issues in this repo — just keep observing).

---

---

# Final Acceptance (Hardening project, based on ee4c195, 2026-11-15, read-only audit)

**Audit baseline verification (measured)**: HEAD=`ee4c195c4c00617220a5f82cafc932f1ebdd3b6e`; branch `remediation/hardening`;
in sync with origin (rev-list 0/0); the baseline commit's own CI run 43711832556 ✓ success (2m16s).
**Working tree anomaly (recorded, not blocking)**: one uncommitted local `.gitignore` change exists (adding an `11*.json` ignore rule),
not part of the acceptance baseline (does not affect committed state or remote sync), not included in acceptance, not self-handled; manual confirmation recommended.

## Item-by-Item Check (12 items)

| # | Item | Conclusion | Basis (code/tests/logs, not self-reported docs) | Remaining Risk |
|---|---|---|---|---|
| 1 | Three paths + 429/503/Retry-After | ✅ Preserved | handler.lua:50 (503 Fail-close), :82 (Retry-After, capped at window); CI measured: handler-fault 26/0, fault-recovery 12/0, exhaustion 11/0, quota.sh allowed=100/other=0 | None |
| 2 | Worker-private inventory / Lease lifecycle / crash handling | ✅ Implemented and verified | lease.lua `_pools` Worker-private; state machine ACTIVE→CLOSED/EXPIRED; worker-crash-e2e 16/0 (sample 10=4+lost6, no takeover/compensation) | Crash-loss exposure (under-grant direction, Phase 7 convention 3.1%) |
| 3 | Concurrent GRANT bound / single in-flight | ✅ Implemented; bound is derived | lease.lua `_inflight` flag (:45), Plan B direct-grant degradation (algorithm.lua:383-408); concurrent-lease-e2e 22/0 (real OpenResty); `W_total×k` is a derived bound (premise = ≤1 active per Pool) | Coroutine-model quantified data NOT VERIFIED (Gate 2 declaration maintained) |
| 4 | Pool cap / reclamation / memory evidence | ✅ Implemented; memory partly measured | MAX_POOLS=10000/Worker (lease.lua:49), 60s Timer, empty-pool EVICTED zero loss; metadata memory measured (Gate 4 Task B: 1M records 306.08MB, real key length estimated 330–350MB ±10%) | Worker RSS and long-duration memory curve NOT VERIFIED (Gate 2 freeze retained) |
| 5 | Ledger relations | ✅ Implemented and verified | Identity `confirmed_granted = consumed + outstanding + discarded` (lease.lua:23 comment and invariants() implementation); discarded's sole source `expire_lease_at`; uncertain tracked separately and excluded (frozen semantics); algorithm-lease-unit 37/0 (N/O group assertions) guarding | Exact lost audit Deferred |
| 6 | Key uniqueness / encoding / hash tag | ✅ Implemented; Cluster behavior unverified | keys.lua encode_value (4-byte escaping) + build_lease_key same tag; config-isolation-unit 24/0 (8 key assertions incl. CRC16 slot equivalence) | Real Redis Cluster NOT VERIFIED (standalone environment, CLUSTER KEYSLOT disabled) |
| 7 | Script dual-source consistency | ✅ Implemented and verified | test/script-consistency-check.sh (comment-stripped line-by-line diff); local 4/0 + CI clean Runner 4/0 (negative verification detects code differences) | Comment-level differences allowed (convention defined) |
| 8 | Lease metadata fields/TTL/cost | ✅ Implemented; cost measured | Script HSET 5 fields + PEXPIRE (redis.lua:274-280); measured PTTL=3,592,908ms (1h); single key 280B, 1M records 306.08MB (Gate 4 Task B measured); TTL expiry ≠ inventory return (frozen convention) | Cluster memory/replication traffic unverified |
| 9 | Schema and configuration documentation consistency | ✅ Consistent | password field schema.lua:149 (encrypted+referenceable+len_min=0) ↔ CONFIGURATION.md:22 word-for-word match; full table previously checked against the schema (Gate 5) | None |
| 10 | Cross-document consistency of five documents | ✅ Consistent (spot check) | MAX_POOLS/max_age=2×window/LEASE_TTL_MS/9.99:1/81.8%/−23%/−73%/NOT VERIFIED attribution consistent across README/design/architecture/CONFIGURATION/REMEDIATION (grep item-by-item hits checked) | mermaid rendering NOT VERIFIED (manual check) |
| 11 | CI and local test entry points | ✅ Consistent | All 18 local test/*.sh covered by CI (4 unit + 2 Redis integration + consistency + 11 E2E + quota.sh); baseline CI run 43711832556 item-by-item log check all PASS | Probes (lease-memory-baseline/lease-concurrent-grant-probe.lua) and manual md not in CI — they are Gate 1 audit tools/manual playbooks, run on demand (reason recorded); CI first full green was 43711556576 |
| 12 | Frozen data integrity | ✅ Complete | `git diff c9e05fc..ee4c195` for bench/raw/, docs/reports/, openspec/, redis/ has diff file count = 0 (schema.lua is Task 2 authorized scope); phase7 raw 97 files, docs/reports 9 files, reports/ 3 files, the two Phase 0 reviews and docs/archive/rule.md all in place | None |

## Five-Category Final Conclusions

**1. Implemented and verified (backed by real tests/CI logs)**: batch=1 per-request authorization and three-path semantics; multi-rule all-or-nothing;
429/503/Retry-After; Fail-close/explicit degradation; EVALSHA+NOSCRIPT retry exactly once; Worker-private Leases and
crash-loss ledger (worker-crash-e2e); concurrency safety (concurrent-lease-e2e real environment); single in-flight GRANT +
Pool cap degradation (no 429/no 503); Pool expiry/reclamation + counted-once discarded + ledger identity;
key encoding and Lease key same tag (8 unit assertions + CRC16 equivalence verification); script dual-source consistency (automated check + CI);
Lease metadata TTL/cost (measured); quota.sh strict quota (CI allowed=100).

**2. Implemented but insufficiently verified (implementation plus unit/E2E evidence exist; specified-environment verification missing)**:
the W_total×k concurrency bound's coroutine quantification (real environment has concurrent-e2e behavioral evidence; quantification NOT VERIFIED);
real Redis Cluster behavior (key-layer same-slot fixed; per-node script caching/redirection unverified);
vault reference rotation (TTL update mechanism); Worker RSS and long-duration memory curve.

**3. Known limitations (declared as-is, kept on record)**: automatic RETURN not wired (RETURN_LEASE protocol frozen, unused);
no Worker takeover/inventory compensation; GRANT uncertainty no-retry no-registration (inventory loss exposure, ≤k per event); fingerprint change old/new bucket
coexistence (upgrade window 2×window); anonymous consumer shared quota (`anon`, Gate 6 decision); N1 dimension value 256-char truncation
collision (unfixed); no normalization for high-cardinality paths; `LEASE_TTL_MS` not configurable.

**4. Still required before Production Ready**: Redis HA (Sentinel/Cluster deployment verification); cross-machine real RTT
load testing and clean-environment p99 attribution; long-duration soak (>24h) and memory curve; Worker RSS collection; monitoring integration (Prometheus);
exact lost reconciliation; hot-key sharding. **This remediation achieved "engineering-verification grade + gate freezes", not Production Ready.**

**5. Not covered this time**: control plane/configuration distribution, multi-tenant billing, global fair queuing, μs-level window alignment (design.md §1.2
boundary, never in scope); session export files (1113/1115/1115-2.json, local untracked) and the local uncommitted
.gitignore change (manual handling recommended).

**Issue list (non-blocking)**: only one — the local uncommitted `.gitignore` change (`11*.json`), evidence in the baseline
verification section; does not affect HEAD/remote/CI; recommend manual confirmation then commit or revert.

**Overall conclusion**: the Hardening remediation (Gates 1–6) was completed per the frozen design and passed full regression (local 341/0 full run +
CI all green); acceptance **PASSED**; Production Ready is not claimed (the category-4 list is prerequisite work for production entry).

