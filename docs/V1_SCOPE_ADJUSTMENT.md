# V1 Scope Reduction Change Report (Phase 4–8 SDD Plan Adjustment)

> Executed per: the V1 delivery-scope reduction directive (2026-11-13).
> This round **only modified SDD documents; no business code / Lua scripts / test
> implementations were modified, and no commit was created**.

## 1. Repository State

- Branch: master; **HEAD before modification = `e1155b5`** (working tree clean); HEAD
  unchanged after modification (no commit in this round).
- Phase 0–3 commits verified in place one by one: `17cfe37` (Phase 0 review), `8b04976`
  (Phase 1 baseline), `e4dd6c8`+`b700417` (Phase 2 EVALSHA), `d53f3f0`+`d30592b`+`e1155b5`
  (Phase 3 Lease data model, matrix 50 items).
- README.md / rule.md / docs/design.md (project delivery documents) contain **no**
  Lease-lifecycle-related descriptions (grep=0) — lifecycle content exists only inside
  the Phase 4 change's SDD, so no project-level document sweep was needed.

## 2. File Changes

| File | Changes |
|---|---|
| `openspec/.../specs/rate-limiting/spec.md` | 6 Requirements annotated with V1 rulings/boundaries: ①Lease mode applicability boundary (return behavior = Phase 5 restoration item) ②ownership and state machine (simplified to ACTIVE→CLOSED) ③lifecycle management (**DEFERRED**) ④⑤the two RETURN items (Lua implemented, not wired into V1 calls) ⑥accounting boundary (no RETURN in V1 ⇒ lost=all unconsumed). 4 overly long descriptions compressed (`--strict` zero issues) |
| `openspec/.../design.md` | Added a "V1 Scope Ruling" section (placed before Context); Goals/Non-Goals rewritten to the V1 basis (automatic lifecycle DEFERRED wholesale, with a 13-item deferral list); D3/D5/D6 annotated with V1 boundaries (D3 simplified state machine, D5 clock DEFERRED, D6 Lua implemented but not wired); Migration Plan rewritten to the V1 version (Phases 0–3 marked complete, Phase 4 simplified / Phase 5 DEFERRED / Phase 6 core / Phase 7 compressed / Phase 8 cleanup) |
| `openspec/.../tasks.md` | Phase 4 rewritten (4.3 exhaustion handling simplified, 4.1 fields removed threshold/clock, no scanner); all Phase 5 tasks tagged [DEFERRED] with a declaration "must not be merged into 4/6"; Phase 6 rewritten (scanner/SIGTERM/shutdown interleaving removed; config-isolation check and V1-basis E2E added); Phase 7 compressed (11 correctness items + three-point performance + matrix evidence check); Phase 8 gained the final delivery document and a Production TODO list (13 deferred items marked "not implemented") |
| `openspec/.../proposal.md` | Added a "V1 Scope Ruling" section at the top |
| No files deleted | — |

**Unmodified**: business code, Lua scripts, test scripts, bench, docs/PHASE*_REPORT,
README, rule.md (Phase 8 delivery-document updates are left for the cleanup phase).

## 3. Scope Adjustments

| Item | Handling | Reason |
|---|---|---|
| Phase 4 Worker-local Lease | **Kept, simplified**: TAKE/GRANT wiring/multi-Worker isolation/exhaustion handling all kept; shutdown-and-return flow removed (CLOSING/RETURN calls/snapshots), lifecycle threshold fields removed, clock injection removed | Automatic return is not an original-requirement item; exhaustion-as-loss is the conservatively safe direction |
| Phase 5 lifecycle | **DEFERRED wholesale** (Clock/FFI, scanner, idle/max, config snapshot, RETURN retry policy) | Not a core deliverable of the original assignment; saves FFI adaptation/timer concurrency/recovery logic |
| Phase 3 RETURN_LEASE Lua | **Kept, not deleted, not modified** (50-item matrix accepted); **the V1 request path does not wire it in** | A completed Redis data-model capability; future inventory reclamation can reuse it directly |
| Phase 6 integration | **Kept, V1 core**: scanner startup/SIGTERM/shutdown interleaving removed; config-isolation check added; regressions all kept | The original assignment's core logic |
| Phase 7 testing | **Compressed**: 11 correctness items + M0/batch=1/batch=10 three points + Phase 3 matrix evidence check (not re-running the full 50-item matrix) | Proving the core value suffices; the Phase 3 matrix is already deterministic evidence |
| Phase 8 cleanup | **Kept** + final delivery document (architecture diagram / 3 flowcharts / Production TODO 13 items marked "not implemented") | The trade-off statement and deliverables the original assignment required |

## 4. Consistency Check (15 items from directive §Nine Step 4)

| # | Check | Result |
|---|---|---|
| 1 | Spec consistent with Design | ✓ The two sides' V1 ruling annotations correspond one-to-one (state machine/lifecycle/RETURN/accounting) |
| 2 | Design consistent with Tasks | ✓ Phase 4/5/6/7/8 tasks agree with Design's V1 boundaries |
| 3 | Phase numbering consecutive without duplicates | ✓ The 0–8 numbering kept; Phase 5 marked DEFERRED without creating empty tasks |
| 4 | V1 must-do separated from Production TODO | ✓ Both Design Non-Goals and Tasks Phase 8.2 list the 13 deferred items |
| 5 | CLOCK_MONOTONIC leftovers | ✓ Only inside the lifecycle Requirement (within the DEFERRED tag) and Design D5 (V1 boundary tag) |
| 6 | idle scanner leftovers | ✓ Same as above (inside the lifecycle Requirement's DEFERRED tag; all Tasks Phase 5 [DEFERRED]) |
| 7 | Automatic RETURN leftovers | ✓ The two Spec RETURN Requirements' V1 boundary tags explicitly state "not wired into V1 calls"; no RETURN tasks in Tasks Phase 4/6 |
| 8 | RETURN Lua ≠ automatic return | ✓ Clearly distinguished in all three of Spec/Design/Tasks ("Lua implemented; not wired into V1 calls") |
| 9 | batch=1 strict mode kept | ✓ Spec/Tasks 6.1 "not a line changed" |
| 10 | batch>1 Lease mode kept | ✓ Spec/Tasks 6.1 |
| 11 | Multi-rule atomic debit kept | ✓ Spec/Tasks 6.1 "not a line changed", and multi-rule produces no Leases |
| 12 | Fail-close kept | ✓ Tasks 6.2 failure-branch check |
| 13 | 429+Retry-After kept | ✓ Spec (pre-existing) + Tasks 7.1-⑩ |
| 14 | Multi-dimensional rate limiting kept | ✓ Verified in Phases 1/3, dims.sh regression kept (6.4/7.1) |
| 15 | Multi-Worker correctness tests and performance tests kept | ✓ Tasks 4.5/6.5/7.1-⑦⑧/7.2 |

`--strict` validation: **zero issues**.

## 5. Testing Status

This round was a pure documentation adjustment; **no business tests were run (NOT
RUN)** — no test results can be faked or missed. Existing test evidence (Phase 2 8/8,
Phase 3 matrix 50/0) is unaffected.

## 6. Follow-Up Implementation Suggestions (adjusted order)

1. **Phase 4 (Worker-local Lease, simplified)**: 4.1 structure → 4.2 TAKE → 4.3
   exhaustion handling → 4.4 GRANT wiring → 4.5 multi-Worker isolation → 4.6 commit.
   Estimated about 40% less work than the original plan (no clock / shutdown-return /
   snapshot).
2. **Phase 6 (request-path integration)**: 6.1 wiring → 6.2 failure semantics → 6.3
   config isolation → 6.4 full regression → 6.5 concurrency-anomaly E2E → 6.6 commit.
3. **Phase 7 (verification)**: 7.1 the 11 correctness items → 7.2 three-point
   performance → 7.3 matrix evidence check → 7.4 report → 7.5 commit.
4. **Phase 8 (cleanup and delivery)**: 8.1 delete store.lua → 8.2 delivery document +
   Production TODO → 8.3 commit.
5. Phase 5 is not scheduled; restoring Phase 5 = a separate initiative for "idle
   automatic return + lifecycle management" in the Production TODO.

## 7. Risks and Items Pending Confirmation

1. **The `remaining+consumed=granted` conservation accounting lacks a "returned" term in
   V1**: no RETURN in V1 ⇒ the accounting simplifies to `granted = consumed + lost`. The
   Spec accounting Requirement has the V1 boundary tag added; **risk**: if the reviewer
   still expects the accounting to include a returned term, the V1 basis needs
   confirmation as acceptable (mathematically equivalent: returned is always 0 and all
   unconsumed is counted into lost).
2. **The Phase 3 RETURN_LEASE Lua becomes "unwired code"**: implemented and verified but
   not called by any request path — **code-coverage tools may flag it as dead code**
   (note during Phase 8 cleanup: **it must not be deleted**; it is an implemented asset
   of the Production TODO).
3. **The V1 values of GRANT_LEASE parameters such as `lease_ttl_ms`/`bucket_ttl_ms`/
   `granted`**: no lifecycle config ⇒ `lease_ttl_ms` needs a fixed value (recommended to
   define the constant at Phase 4 implementation, e.g. 3600000=1h, serving only as the
   Redis record cleanup period and not affecting correctness) — **must be confirmed at
   Phase 4 implementation**.
4. **Redis record accumulation**: no RETURN / no reclamation in V1 ⇒ Lease records
   (expiring after TTL) rely on TTL cleanup in the crashed-Worker scenario; record counts
   under high-frequency GRANT need observation in Phase 7 (already listed in the 7.2
   collection items).
5. **Comparability of the Phase 1 baseline**: Phase 1 data is from the Legacy aggregated
   inventory implementation; when comparing Phase 7's batch=10 data against it, **the
   different implementations must be noted** (the Phase 1 baseline serves only as a
   load-magnitude reference, not a per-ms comparison).
6. **Unresolved design rulings**: none — the three rulings checked at kickoff (phase
   mapping / Lease Key / field names) were confirmed and landed in the previous round.
