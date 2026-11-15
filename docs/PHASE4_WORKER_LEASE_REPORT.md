# Phase 4 Group Test Report: Worker-Local Lease (Tasks 4.1–4.6)

- **Date**: 2026-11-13
- **HEAD baseline**: `089e588` (after the V1 design wording fix)
- **Task group**: tasks.md Phase 4 (implementation spec Phase 4: Worker-local Lease, no request-path integration, no scanner; unit tests first)
- **commit**: `feat: add worker local lease manager`

## 1. Implementation Scope

| Task | Content | Status |
|---|---|---|
| 4.1 | `lib/lease.lua` Worker-level module table: pools/leases structures, lease object's seven fields, conservation invariant | Done |
| 4.2 | TAKE non-yield synchronous section: look up ACTIVE → decrement → ALLOW / NEED_GRANT; yield probe | Done |
| 4.3 | Exhaustion handling (V1 simplification): remaining=0 ⇒ CLOSED/removed from the consumable set/retained for diagnostics; no RETURN, no snapshot | Done |
| 4.4 | GRANT call wiring: lease_id generation, four-way classification, multiple Leases coexisting (append, never overwrite), structural assertions | Done |
| 4.5 | Multi-Worker isolation: dual resty processes (= dual VMs) verifying mutual invisibility / no cross-management / in-process singleton | Done |
| 4.6 | Group test report + commit | Done |

**Explicitly not done (confirmed out of scope)**: `algorithm.lua`/`handler.lua`/`schema.lua`/`store.lua` untouched by a single line (request-path integration belongs to Phase 6); Phase 5 lifecycle content completely untouched; `lib/redis.lua` received only the **purely additive** `grant_lease()` call function (the script was registered in Phase 3 with no caller); the existing `grant`/`grant_multi`/evalsha paths unchanged.

## 2. Modified File List

| File | Change | Reason |
|---|---|---|
| `kong/plugins/rate-limit-advanced/lib/lease.lua` | **added** | Tasks 4.1–4.4: Worker-local Lease manager |
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | purely additive `_M.grant_lease()` (+36 lines) | Task 4.4: GRANT_LEASE call transport layer (reuses connect/evalsha/parse_grant_response) |
| `test/lease-unit.lua` + `test/lease-unit.sh` | **added** | Tasks 4.1–4.4 resty unit tests (25 assertions) |
| `test/lease-iso.lua` + `test/lease-isolation.sh` | **added** | Task 4.5 dual-VM isolation verification (7 assertions) |
| `test/lease-grant-smoke.lua` + `test/lease-grant-smoke.sh` | **added** | Task 4.4 real-path smoke (11 assertions, including a CLIENT PAUSE construction) |
| `openspec/changes/.../tasks.md` | 4.1–4.6 checked off | Task completion markers |

## 3. Core Implementation Notes

### 3.1 Data Structures (design D2 frozen structure)
- `pools[pool_key] = { leases = {...} (full diagnostic, append-only), active = {...} (consumable set, insertion order) }`
- lease object: `lease_id / pool_key / granted / remaining / consumed / created_at / state`
- **Field name note**: tasks.md 4.1 writes `status`; design.md D2 freezes `state` ("ACTIVE"|"CLOSED"). The implementation follows design.md ⇒ adopts `state` (the Redis-side record field remains `status`, consistent with Phase 3 Lua).

### 3.2 TAKE Atomicity (D2/D3)
- Lookup/check/decrement/(CLOSED marking + removal on exhaustion) complete within the same non-yield section; a coroutine probe asserts completion within a single `coroutine.resume` (status=dead) ⇒ no yield inside the section.
- Exhaustion ⇒ `state="CLOSED"` + `table.remove(active)`; the object is retained in `leases` for diagnostics only; CLOSED cannot be revived (absent from the active set ⇒ never selected by TAKE).
- No Redis access, no waiting, no compensation path (structural assertions carried by `invariants()`).

### 3.3 GRANT Four-Way Classification (D4)
- `success` (granted≥1 ⇒ register) / `insufficient` (granted=0 ⇒ 429 semantics, not registered) / `explicit_error` (LEASE_EXISTS / INVALID_ARGUMENT / script loading failure — deterministically not executed, zero writes) / `uncertain` (timeout/disconnection/malformed — may have executed ⇒ **no retry, no registration**, loss allowed).
- lease_id: `<hostname>:<worker>:<in-process monotonic counter>:<random hex>`; uniqueness assertion over 1000 generations passes.

### 3.4 Conservation and Ledger (D8)
- Structural invariant function `invariants()`: `remaining+consumed=granted`, `0≤remaining≤granted`, `state∈{ACTIVE,CLOSED}`, CLOSED⇒remaining=0, no duplicates in the active set / no non-consumable objects, no counter drift; 100 random operation sequences assert pass.
- V1 ledger identity `granted = consumed + outstanding` (no loss sequences) asserts pass (100/80/20/0).

## 4. Test Matrix and Actual Results

| Test | Command | Result |
|---|---|---|
| Lease unit test (25 assertions: structure/conservation/TAKE/insertion order/coexistence/yield probe/exhaustion CLOSED/four-way classification/no-retry no-registration/lease_id uniqueness/ledger identity) | `bash test/lease-unit.sh` | **PASS 25/25** |
| Multi-Worker isolation (dual processes dual VMs: mutually invisible/TAKE takes only its own/in-process singleton) | `bash test/lease-isolation.sh` | **PASS 7/7** |
| GRANT real-path smoke (real EVALSHA grant + Redis record/debit evidence; CLIENT PAUSE timeout ⇒ uncertain no-retry no-registration + zero Redis-side writes evidenced) | `bash test/lease-grant-smoke.sh` | **PASS 11/11** |
| Phase 2 evalsha unit regression | `bash test/evalsha-unit.sh` | **PASS 8/8** |
| Phase 3 Lease bare-Redis matrix regression (serial re-run) | `bash test/lease-redis-matrix.sh` | **PASS 50/50** |
| Phase 1 quota regression batch=1 (strict 100/350/0) | `bash bench/quota.sh -l 100 -b 1 -p 150` | **PASS** |
| Phase 1 quota regression batch=20 (range [40,100]) | `bash bench/quota.sh -l 100 -b 20 -p 150` | **PASS** (utilization 100%, under-grant 0) |
| Phase 2 dims regression | `bash bench/dims.sh` | **PASS 8/8** |
| Phase 3 rules regression | `bash bench/rules.sh` | **PASS 14/14** |
| Phase 7 performance three-point / kill -9 loss verification / Phase 6 request-path integration | — | **NOT RUN** (Phase 6/7 tasks, outside this group's scope) |

## 5. Findings and Dispositions During Implementation

| # | Finding | Disposition |
|---|---|---|
| 1 | **LuaJIT `math.random` cross-VM deterministic collision**: unseeded, every new VM outputs the identical sequence ⇒ lease_ids with the same host+worker+counter start are fully identical across restarts; measured GRANT hitting a leftover record returned `LEASE_EXISTS` (the Redis backstop correctly rejected per the frozen decision, zero overwrites) | `lib/lease.lua` seeds before each VM's first generation (millisecond time + Worker PID entropy source); uniqueness assertion re-run passes. D4's "generation rule makes collision probability ≈0" now holds |
| 2 | **Test infrastructure parallel interference (pre-existing constraint, not introduced this time)**: `bench/rules.sh`/`bench/dims.sh` run `FLUSHDB` between scenarios; running in parallel with the Phase 3 matrix wipes the matrix's pre-seeded bucket state ⇒ first parallel run produced 5 FAILs, individual re-runs 50/50 over three rounds | All regressions switched to **serial** execution; matrix re-run alone **50/50 PASS** (first-round failure items not individually documented; recorded as-is as parallel FLUSHDB interference) |
| 3 | **Empirical semantics of CLIENT PAUSE + client timeout**: client read timeout ⇒ OpenResty cosocket closes the connection ⇒ Redis **no longer executes** queued EVALSHAs on the disconnected connection (measured: after the pause expires, the bucket was not debited and no Lease record exists ⇒ zero writes under this construction). Design Context fact 5's "executed but response lost" construction does not hold under the resty transport layer — unless the timeout occurs while the script is executing (not queued) | smoke assertions converged factually to the empirical result (`pause-not-executed-*`); the classification layer stays conservative (no-retry/no-registration) unchanged; the "timeout during script execution ⇒ executed loss" branch cannot be constructed with the frozen scripts, NOT RUN, recorded as a known limitation |

## 6. Comparison Against Frozen Decisions

- batch=1 strict path: untouched (quota.sh re-run consistent) ✓
- Multi-rule GRANT_MULTI: untouched (rules.sh all green) ✓
- Multiple Leases coexisting/append never overwrite/TAKE insertion order: unit + grant smoke assertions ✓
- Exhaustion CLOSED/removal/retained for diagnostics/no RETURN: unit assertions ✓
- GRANT timeout no-retry no-registration: unit + CLIENT PAUSE smoke assertions ✓
- Worker isolation/no takeover: dual-VM verification ✓
- Fail-close/429/Retry-After semantics: this group did not touch the request path; Phase 6 checks (NOT RUN)

## 7. Known Limitations

1. V1 has no inventory reclamation: CLOSED Lease objects and Redis OPEN records persist per process/TTL lifecycle (frozen decision; RETURN/cleanup introduced when Phase 5 revives).
2. `pool.active` is an insertion-order linear scan; the GRANT total over a single Worker's lifetime is the upper bound (covered by the Phase 7 batch=10 performance measurement).
3. The "timeout during script execution ⇒ executed loss" branch has no deterministic E2E (see finding #3).
