# Proposal

## Why

The MVP requirements mandate "multi-dimensional control granularity covering Request Path / Client ID / IP, etc."; Phase 2 verified the **single-rule composite key** (`limit_by=[consumer,path]` = one bucket), but real business also needs **multi-rule joint decisions**: the same request is simultaneously constrained by two independent quotas—"consumer global 100/hour" and "consumer×path 10/hour"—and is admitted **only when all buckets have tokens**; and when any bucket is short, **no bucket is consumed** (all-or-nothing, an atomicity requirement the user explicitly raised after manual acceptance). The current single-bucket semantics cannot express this, and no configuration can work around it—it requires multi-key atomic decisions and a new key structure; it is an independent structural capability.

## What Changes

- **α strong-consistency mode (decided by the user)**: the multi-rule mode has **no local inventory** and no batch lease—each request performs one Redis **multi-key atomic Lua**: all buckets have ≥1 ⇒ deduct 1 from each and admit; any bucket short ⇒ deduct from none and return the list of insufficient rules (strong consistency: check and deduction complete within a single-threaded Redis script, with no local rollback window). This choice also makes the "node restart loses leases" problem nonexistent in the multi-rule mode.
- **Configuration model**: the schema adds a `rules` array (each rule containing limit/window/burst/limit_by/header_name); a single plugin instance declares a group of rules; `rules` and `limit_by` are **mutually exclusive** (co-present → 400 at deployment); with `rules` non-empty, `batch > 1` → 400 (batch is meaningless in α mode, fail fast); the rule count is capped at 8 (bounded script key count). The existing `limit_by` single-rule form is **completely unchanged**.
- **Group key structure**: `kong:rl:{<ns>:<group fingerprint>:r<i>:<dim>=<val>:…}`—the group fingerprint = FNV-1a over all rule parameters; **any rule change ⇒ the whole group gets new buckets** (cost: changing one rule = resetting the whole group's quota, documented); all buckets in a group share the same hash tag ⇒ the same Redis Cluster slot (the forward fulfillment of the original hash tag design, a precondition for Cluster deployment).
- **Multi-rule response semantics**: on admission, `X-RateLimit-Remaining` = the minimum across buckets (the bottleneck rule), `X-RateLimit-Reset` = the bottleneck rule's next-token moment; the 429 response body gains a `rule` field identifying the rejection source, `Retry-After` = the maximum wait across the insufficient rules (capped = the maximum of the insufficient rules' windows); the decision log includes the rejected rule.
- **Verification**: add `bench/rules.sh`—the core scenario "R1 empty + R2 non-empty ⇒ 429 and both buckets' tokens unchanged" (direct acceptance of all-or-nothing), plus full-quota admission, group key isolation, bad configuration 400, and single-rule regression.

## Capabilities

### New Capabilities

(None)

### Modified Capabilities

- `rate-limiting`: ADDED requirements for the multi-rule joint decision—multi-bucket all-or-nothing atomicity, group key structure and group fingerprint, strong-consistency mode constraints (mutual exclusion/cap/batch), multi-rule response semantics. The existing 19 requirements are unchanged.

## Impact

- **Code**: `schema.lua` (the rules field + extended entity_checks), `lib/redis.lua` (the multi-key script + parse_multi_grant_response), `lib/algorithm.lua` (the multi-rule decision branch), `handler.lua` (multi-rule response semantics); `lib/store.lua` untouched (the rules mode does not use local inventory)
- **Tests**: add `bench/rules.sh`; the existing dims.sh/quota.sh are unaffected (single-rule regression)
- **Docs**: `README.md` (rules configuration and response headers), `docs/design.md` (§2/§4 multi-rule atomicity), `docs/architecture.md` (the decision flow diagram gains the multi-rule branch), `rule.md` (the key structure and the α decision record)
- **Behavioral impact**: purely an added capability (`rules` is a new field; old configuration behavior unchanged); a Redis Cluster deployment changes from "forward compatible" to "a hard prerequisite for multi-rule" (same slot within the group)
- **Explicitly not doing** (left for later): multi-rule local inventory/batch leases (the β enhancement; the user decided α first), graceful L2 return on node restart (Phase 4, affecting only single-rule batch>1), lease reconciliation L3, joint decisions across plugin instances (structurally infeasible, see design D1)
