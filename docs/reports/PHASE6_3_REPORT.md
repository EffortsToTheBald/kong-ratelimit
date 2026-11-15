# Phase 6.3 Report: Config Isolation and Config Change E2E

- **Date**: 2026-11-13
- **HEAD before execution**: `146fdde` (after the 6.2 fix); workspace clean (only the untracked `1113.json` session export)
- **Task**: tasks.md 6.3 — different rate-limiting policy configurations must use different local lease pools; new configurations must never reuse old inventory
- **commit**: `test: complete phase6.3 config isolation evidence`

## 1. Conclusion: Scenario A — the existing implementation already satisfies the contract, zero production code changes

| Code location | Evidence |
|---|---|
| `lib/algorithm.lua:35-53` `fingerprint_input` | Fingerprint input segments: `limit=` / `window=` / `burst=` (normalized via `rate_and_burst`: burst≤0 ⇒ limit) / `limit_by=` concatenated dimension by dimension; `header_name=` is appended only when the limit_by dimensions include `header` (without a header dimension, this field is meaningless to bucket identity — semantically correct) |
| `lib/algorithm.lua` (no batch segment) | `batch` does not participate in the policy fingerprint (frozen decision: batch is a transport batching property, not policy identity) |
| `lib/algorithm.lua` `build_key` | Bucket key = `prefix:{ns:p=<fingerprint>:<dim>=<val>...}`; `policy_fingerprint` = FNV-1a32(fingerprint input) |
| `lib/lease.lua` `_M._pools[pool_key]` | Local pool identity = the bucket key itself ⇒ config isolation is inherently carried by the fingerprint; **no second pool_key system independent of the bucket key exists** (D7) |

## 2. Per-dimension verification of the five configuration dimensions (unit test `config-isolation-unit.sh`, 15/15 PASS)

The verification targets the **actual output of `algorithm.build_key()`** (not an independent helper function):

| Dimension | Change method | Result |
|---|---|---|
| Fully identical configuration | Two independent conf instances | key identical ✓ (same-config-same-key) |
| limit | 100→200 | key different ✓ |
| window | 3600→7200 | key different ✓ |
| burst | 0→5 | key different ✓ |
| limit_by | {ip}→{ip,method} (single field only; per-dimension independent proof after the review fix) | key different ✓ |
| header_name | X-A→X-B (both configurations include the header dimension) | key different ✓ |
| batch (control) | 10→20 | **key identical** ✓ (frozen: batch is not in the fingerprint) |
| burst=nil vs 0 (control) | Normalization equivalence (burst≤0⇒limit) | key identical (semantically equivalent configurations, noted) |

## 3. Local pool isolation unit test (same suite, transport stub driving the real `check_lease` path)

- Configuration A: GRANT granted=5 → consume 1 → 4 remaining locally (1 transport call)
- Configuration B (limit=200 ⇒ new fingerprint): **must issue a new GRANT** (1 more transport call ⇒ did not reuse A's 4 units of inventory), registers B's own pool (`_pools[kB] ≠ _pools[kA]`)
- Pool A untouched field by field: `remaining=4 / consumed=1 / active=1`
- A requested again: local TAKE succeeds (**zero** transport calls) ⇒ A's inventory survives independently after B's request
- Identical configuration (new table instance) ⇒ hits the same pool (`_pools[kA3] == _pools[kA]`)

## 4. Real-stack E2E of configuration changes (`config-isolation-e2e.sh`, 14/14 PASS)

Real Admin API configuration change (no mocks), limit 100→200, same namespace:

| Assertion | Measured |
|---|---|
| First request under config A | 200, X-RateLimit-Remaining=9 (granted=10, consume 1, 9 remain locally) |
| First request under config B | 200, Remaining=**9** — if A's 9 remaining units were reused it would be 8 ⇒ **empirically no reuse** |
| New GRANT triggered | ns lease record count = 2 (B's first request is itself a new GRANT) |
| Pool isolation | A pool_key `p=50780f62` vs B pool_key `p=95b99e16` (fingerprint segments differ) |
| Coexistence without overwrite | B lease_id `...:0:64:32d404` ≠ A lease_id `...:0:63:77be70` |
| A's records untouched | lease_id / created_at / status=OPEN all unchanged (V1 has no RETURN; the old pool's inventory naturally drains / expires via TTL — frozen decision) |
| Old bucket untouched | A bucket tokens 90→90 (±1 tolerance = refill/exec interval; a config change does not modify the old bucket's token state) |
| B bucket independent | B bucket key ≠ A bucket key |

Dimension coverage scope: the E2E performs a real configuration change for the **limit** dimension only (§5.2 "at least one dimension"); the window/burst/limit_by/header_name four dimensions are covered by the unit-test matrix (allowed combinations per §5.3).

## 5. Regression tests (executed serially)

| Test | Result |
|---|---|
| `bash test/lease-unit.sh` | PASS 25/25 (zero regression in the lease manager) |
| `bash test/algorithm-lease-unit.sh` | PASS 17/17 (zero regression in 6.1) |
| `bash test/algorithm-lease-e2e.sh` | PASS 15/15 |
| `bash test/handler-fault-e2e.sh` | PASS 26/26 (zero regression in 6.2) |
| `bash test/config-isolation-unit.sh` | PASS 15/15 |
| `bash test/config-isolation-e2e.sh` | PASS 14/14 |
| `git diff --check` | ✓ pass |
| Phase 0–3 full suite (dims.sh/rules.sh/lease-redis-matrix.sh/quota.sh) | **NOT RUN** (belongs to the 6.4 full-regression task group; not executed by this group) |

## 6. PASS / FAIL / NOT RUN statistics

- **PASS 112** (15+14+25+17+15+26) / **FAIL 0** / **NOT RUN: 6.4 full-regression suite + 6.5 concurrency/exception E2E + 6.6**
- No unexecuted tests were counted as PASS

## 7. Open items

1. The old pool's local diagnostic objects remain in worker memory after a config change until process end (the `leases` table only grows, never shrinks — V1 frozen decision; reclamation will be introduced in Phase 5 when RETURN is restored)
2. The E2E performed a real change for the limit dimension only (unit tests cover all dimensions); a real-change E2E for each of the five dimensions would be costly with limited benefit — recommend keeping the status quo
3. `burst=nil` and `burst=0` are normalization-equivalent (same fingerprint) — semantically equivalent configurations, not a defect; archived in this report

## 8. Conclusion for entering Phase 6.4

- All config-isolation contract items are satisfied; the implementation requires zero changes and the test evidence is complete — ready to enter 6.4 (full regression + fault dual paths).
- The review fix item (limit_by single-dimension) has been implemented and re-verified with a pass.
