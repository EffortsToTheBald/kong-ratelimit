# Design

## Context

- User decision record (discussion after Phase 2's manual acceptance on 2026-11-11): the multi-rule joint decision adopts the **α strong-consistency mode**—no local inventory, no batch lease; each request performs one Redis multi-key atomic Lua. Rationale chain: the local shared dict has no multi-key atomic primitive; "check A, B first, then deduct" is a TOCTOU race locally (a passed check ≠ a successful deduction, so a rollback mechanism is needed anyway); Redis single-threaded + multi-key single-script with same-slot within the group is the only layer that can provide "check and deduction indivisible". α also makes "node restart loses leases" (the L2 return problem) nonexistent in the multi-rule mode.
- **Cross-plugin-instance joint decision is structurally infeasible**: two independent plugin instances are invisible to each other and cannot decide their respective buckets within one atomic operation—so multi-rule must converge to **a single plugin instance declaring a group of rules**. This makes the configuration model (the rules array) this change's biggest structural change.
- Existing facts: single-rule composite keys (verified in Phase 2), policy fingerprint (Phase 1), entity_checks pre-validation (Phase 2), fail-closed default (Phase 1), and same-slot within the group was the forward-compatibility promise of the original hash tag design.
- Under the `rules` mode, each request consumes exactly 1 token per bucket (batch=1 semantics), so the batch field loses meaning—to prevent misleading, the schema rejects rules+batch>1.

## Goals / Non-Goals

**Goals:**

- Multi-bucket "all-or-nothing" atomic decision (a single script on the Redis server side), returning the insufficient rules on rejection.
- Configuration model: the rules array + three pre-validations (mutually exclusive with limit_by, batch∈{0,1}, ≤8 rules).
- Group keys: the same hash tag + a group fingerprint (any rule change ⇒ the whole group gets new buckets).
- Multi-rule response semantics (bottleneck basis + 429 identifying the rejected rule).
- Zero regression of the single-rule form.

**Non-Goals:**

- Multi-rule local inventory and batch leases (the β enhancement, a later change; α is decided to come first).
- Graceful L2 return on node restart / lease reconciliation L3 (Phases 4/5; affecting only the single-rule batch>1 mode).
- Cross-plugin-instance joint decisions (structurally infeasible, explicitly stated in docs).
- Per-rule independent TTL tuning; adding/removing rules dynamically without changing buckets (excluded by the group fingerprint semantics).

## Decisions

### D1. α: multi-rule = one multi-key atomic Lua per request, no local inventory

- `check()` detects non-empty `conf.rules` → takes the multi-rule branch: construct all bucket keys (same tag within the group) → the new `redis.lua` function `grant_multi(conf, keys, want=1)` → "check-all, deduct-all / deduct-none" within a single script.
- Does not touch `store` (no take/fill); the batch field does not participate (the schema rejects >1).
- Consequence: the multi-rule mode costs 1 RTT per request (no fast path)—the direct price of strong consistency, decided by the user; the restart-loses-leases problem does not exist in this mode.
- The alternative β (local multi-pool leases + deduct-verify-rollback) was rejected for v1: although the crash window leaks ≤N−1 tokens in the under-admission direction, the intent of "check first, then deduct" is strong consistency; β remains a later enhancement.

### D2. Configuration model and three pre-validations

```lua
{ rules = {
    type = "array", len_max = 8,
    elements = { type = "record", fields = {
      { limit = integer, required },
      { window = number, default 60 },
      { burst = integer, default 0 },
      { limit_by = array (same as DIMENSIONS, default {"consumer"})},
      { header_name = string },
    } },
} },
```

- entity_checks gains three more (continuing Phase 2's conditional/contains technique, with custom_entity_check if necessary):
  1. `rules` non-empty ⇒ `config.limit_by` must not be explicitly set—**implementation note**: `limit_by` has the default `["ip"]`, and "explicitly set" cannot be distinguished from the projection. A feasible approach: when rules is non-empty, **ignore and warn**? No—ambiguity must be hard-rejected. Landing plan: make the `limit_by` default nil (making it required would break old configurations—no). **Final plan**: rules non-empty + `limit_by ≠ ["ip"]` (the default) → 400 rejection (compared in a custom_entity_check); equal to the default is treated as unset (documented: limit_by is ineffective under the rules mode). Measure the behavior of this comparison inside entity_check on implementation day one.
  2. `rules` non-empty ⇒ `config.batch` ∈ {0,1} (batch>1 → 400).
  3. `#rules ≤ 8` (expressed directly by len_max).
- The runtime backstop (at the build_key/check entry) validates in sync—a double guard.

### D3. Group key structure

```
kong:rl:{<ns>:<group fingerprint>:r<i>:<dim>=<val>:…}
```

- Group fingerprint = FNV-1a (each rule's limit/window/parsed burst/limit_by/header_name concatenated in order)—any rule change ⇒ the group fingerprint changes ⇒ the whole group gets new buckets (old buckets evicted by TTL; the cost is documented).
- `r<i>` is the rule index segment (i = the rule's index in the rules array); the dimension value segment matches the single-rule form.
- All buckets in a group share the same hash tag ⇒ the same slot: the Cluster precondition of multi-key EVAL; invisible on a single-instance Redis.
- The in-bucket hash fields reuse `tokens`/`ts` (isomorphic to the single-rule bucket; the script reuses the refill formula).

### D4. Multi-key atomic script (grant_multi)

```
KEYS: r1 bucket key, r2 bucket key, … rN bucket key
ARGV: [n, r1_rate, r1_burst, r1_ttl, r2_rate, …]
Logic (single script, Redis-serialized):
  1. Per bucket HMGET tokens/ts → refill (TIME monotonic, burst cap, same formula as the single-bucket script)
  2. Check all: after refill, do all buckets have tokens ≥ 1?
  3. All sufficient → per bucket HSET(tokens-1, ts=now) + PEXPIRE(each bucket's ttl_i) → return {ok=1, each bucket's tokens/wait}
     Any insufficient → write to no bucket → return {ok=0, list of insufficient rule indices, each insufficient bucket's wait}
```

- The wait formula reuses the unified basis `max(0,(1−tokens)/rate)` (computed only for insufficient buckets).
- The return value is still a flat array (the Redis Lua return convention); the pure-function defensive validation `parse_multi_grant_response(keys_count, want)` (continuing Phase 2's D3 technique: structure/numerics/ranges); malformed → close + nil,err → the failure branch.
- The single-bucket script (the single-rule path) is retained untouched; a new standalone script file `redis/multi_bucket.lua` is added, dual-source synced with the embedded one (continuing Phase 1's dual-source convention and diff verification).

### D5. Multi-rule response semantics

- Admission: `Remaining = min(each bucket's remainder)` (the bottleneck rule), `Reset = the bottleneck bucket's now+wait` (wait=0 means now); the log contains all rules' keys.
- 429: the response body's `rule` = a human-readable identifier of the insufficient rule (e.g., `rules[2]:consumer+path`); `Retry-After = max(insufficient buckets' wait)` capped at `max(insufficient buckets' window)`; Reset and Retry-After share the basis (continuing Phase 2's basis); the decision log includes the rejected rule.
- The response header basis is annotated as "bottleneck rule perspective" in README/design.

### D6. Compatibility and regression boundary

- Without `rules` (limit_by only) → the existing single-rule path is untouched line by line (batch leases, local inventory, fast/slow paths, Phase 2 response header semantics all retained).
- dims.sh / quota.sh / xff.sh all run the single-rule form → they automatically become the regression defense line.
- The new verification `bench/rules.sh` is a separate script (not merged into dims.sh, separation of concerns): the core scenario uses redis-cli HSET to preset bucket states, directly constructing "one empty, one non-empty", accepting "429 and both buckets' tokens unchanged" (the user's original acceptance criterion).

## Risks / Trade-offs

- [The complexity and correctness of the multi-key script] → the script logic is isomorphic to the single-bucket script (refill formula reused); the only difference is "check all, deduct all"; resty pure-function unit tests + redis-cli standalone bare-run of the script (token_bucket.lua's Day-1 technique) verify first, then wire into the plugin.
- [The imprecise distinction between limit_by's default and "explicitly set"] → adopt the approximate semantics "rules non-empty + limit_by ≠ default → 400", documented that limit_by is ineffective under the rules mode; measure the comparison on implementation day one; if imprecise, degrade to "ignore limit_by under the rules mode + init warn" and revise the spec wording (the risk chain is annotated).
- [The group fingerprint's reset semantics] → changing any rule = resetting the whole group's quota, documented in README/design; the escape hatch remains the namespace.
- [The 429 `rule` field exposes internal structure] → the field is a human-readable rule description rather than a bare internal index; for gateway callers it is diagnostic information, the benefit outweighs the harm.
- [Cluster precondition] → invisible on a single-instance Redis; under Cluster deployment, multi-rule must guarantee same-tag within the group (already guaranteed by this design); docs annotate "Cluster is a hard prerequisite for multi-rule".
- [The performance cost of 1 RTT per request] → decided by α; the Phase 4 performance matrix treats the multi-rule mode as an independent measurement point to quantify.

## Migration Plan

1. Baseline commit; on implementation day one, measure D2's entity_check approximate semantics (if imprecise, take the degraded plan and revise the spec wording).
2. schema (rules + the three validations) → verify the 400/201 matrix with resty.
3. `redis/multi_bucket.lua` + the embedded multi-key script → redis-cli bare-run verifying check-all-deduct-all → plugin wiring + `parse_multi_grant_response` unit tests.
4. algorithm/handler multi-rule branch + response semantics.
5. `bench/rules.sh` all green; dims.sh/quota.sh regression all green (zero single-rule regression).
6. Docs sync (README/design/architecture/rule.md) → `reports/phase-3-multi-rule.md` (§13 format).
7. Rollback: reverting the group-level commit; the new key structure has no persistence migration issue (old buckets evicted by TTL).

## Open Questions

(None blocking. The precision of D2's limit_by "explicitly set" determination is a day-one fact check; the degraded path is annotated.)
