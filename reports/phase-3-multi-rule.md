# Test Report — Phase 3 Multi-Rule Joint Decision (α Strong-Consistency Mode)

## 1. Test Purpose

Verify the core semantics of the `rules` multi-rule mode (the spec's 5 ADDED requirements):

1. **Multi-bucket all-or-nothing atomicity**: one empty, one non-empty ⇒ 429 with both buckets' tokens unchanged; all sufficient ⇒ deduct 1 from each and admit.
2. **Group key structure and group fingerprint**: the same hash tag within the group; changing any rule ⇒ the whole group changes buckets.
3. **Strong-consistency mode configuration constraints**: rules+limit_by mutual exclusion / batch∈{0,1} / ≤8 rules, with violations rejected at deployment with 400.
4. **Multi-rule response semantics**: admission headers on the bottleneck basis; the 429 body's `rule` field + Retry-After cap.
5. **Zero regression of the single-rule form**: dims.sh / quota.sh / the dual failure paths match the existing anchors.

## 2. Modified Files

| File | Content |
|---|---|
| `kong/plugins/rate-limit-advanced/schema.lua` | the `rules` array field + custom_entity_check (mutual exclusion/batch/header_name, three constraints combined) |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | group key construction (group fingerprint + r<i> segment), `check_multi()`, and the `validate_rules()` runtime backstop |
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | the embedded `GRANT_MULTI` multi-key script, `grant_multi()`, and `parse_multi_grant_response()` defensive validation |
| `kong/plugins/rate-limit-advanced/handler.lua` | multi-rule response semantics (bottleneck headers / the 429 rule field / reject_cap) |
| `redis/multi_bucket.lua` | a standalone bare-run multi-key script (dual-source synced with the embedded one) |
| `bench/rules.sh` | a verification script with 5 scenarios and 14 assertions (new) |
| README / docs/design.md / docs/architecture.md / rule.md | docs sync |

## 3. Changes Made (corresponding to design D1–D6)

- **D1 (the α decision)**: the `check()` entry detects non-empty `conf.rules` → `check_multi()`—no local inventory (store untouched), no batch lease; each request performs one `grant_multi` multi-key atomic Lua.
- **D2 (configuration model)**: the `rules` array (elements limit/window/burst/limit_by/header_name, len_max=8) + three pre-constraints via `custom_entity_check` (including a userdata defense during init); the `build_key` entry has the `validate_rules` runtime backstop (a double guard).
- **D3 (group keys)**: `kong:rl:{<ns>:g=<group fingerprint>:r<i>:<dim>=<val>:…}`; the group fingerprint = FNV-1a over all rule parameters concatenated in order.
- **D4 (the multi-key script)**: KEYS = r1..rN bucket keys, ARGV = [n, each rule's rate/burst/ttl]; per-bucket refill (TIME monotonic / burst cap, same formula as the single bucket) → check all → deduct all / deduct none; returns `{1, tokens_i, wait_i,…}` or `{0, rule indices, wait,…}`.
- **D5 (response semantics)**: on admission, remaining=min(each bucket's remainder) / reset=the bottleneck bucket's next-token moment / multi_limit=the bottleneck rule's limit; on 429, retry_after=max(insufficient buckets' wait) capped at max(insufficient buckets' window), the body contains the `rule` human-readable identifier, and the decision log includes reject.
- **D6 (compatibility)**: the single-rule path is untouched line by line (dims.sh/quota.sh all green as evidence); `redis/multi_bucket.lua` and the embedded script diff to empty.

## 4. Test Environment

Consistent with Phases 1/2: 3× Kong 3.6 DB-less (kong1/2/3, proxy 8030/8010/8020) + Redis 7 + http-echo;
k6 v0.54.0 (for the quota.sh regression); Docker 29.3.0 / compose v5.1.0.

## 5. Test Parameters

- Scenario rules: `[{limit:10,window:60},{limit:5,window:60,limit_by:[consumer,path]}]` (an independent namespace per scenario)
- Preset buckets: `HSET tokens <v> ts <now+30>` (freezing refill, so asserted values are exact)
- Quota baseline: limit=100 / window=3600 / batch=1 / per_node=150

## 6. Test Commands

```bash
./bench/rules.sh                                 # 5 scenarios, 14 assertions
./bench/dims.sh                                  # single-rule regression (8 assertions)
./bench/quota.sh -l 100 -b 1 -p 150              # batch=1 baseline
# Dual failure paths: docker compose stop redis → default 503 / fault-tolerant configuration 200+degraded
# redis-cli --eval redis/multi_bucket.lua ...  # standalone script bare-run (3.2)
# resty unit tests: parse_multi_grant_response / validate_rules
```

## 7. Test Results

| # | Verification | Result | Expected | Status |
|---|---|---|---|---|
| 1 | 1.2 mutual exclusion semantics (rules + explicit limit_by=["consumer"]) | 400 + mutual-exclusion message | rejected at deployment | ✅ |
| 2 | 1.2 approximate semantics (rules + omitted/explicit ["ip"]) | 201 / 201 | the default value treated as unset (as declared in D2) | ✅ |
| 3 | 1.2 limit_by only (no rules) | 201 | no false kills | ✅ |
| 4 | 2.1 rules + top-level limit_by co-present | 400 | one of the three bad configurations | ✅ |
| 5 | 2.1 rules + batch=20 | 400 (`config.batch: batch must be 0 or 1 under the rules mode`; the server message is emitted in Chinese) | rejected at deployment | ✅ |
| 6 | 2.1 9 rules | 400 (len_max=8) | rejected at deployment | ✅ |
| 7 | 2.1 a legal 2-rule configuration | 201 | deploys normally | ✅ |
| 8 | 2.2 old configuration regression | limit_by-only + batch=20 → 201; dims scenario configurations deploy successfully | zero impact | ✅ |
| 9 | 3.1 dual-source diff | empty | GRANT_MULTI ≡ multi_bucket.lua | ✅ |
| 10 | 3.2 bare-run one empty, one non-empty | `{0, rule 1, wait≈9.5}` (the "rule" element is a Chinese label in the raw return), both buckets 0/5 unchanged | deduct from none | ✅ |
| 11 | 3.2 bare-run all sufficient | `{1, 4.04, 0, 4.08, 0}`, each bucket decremented by exactly 1 | deduct 1 from each | ✅ |
| 12 | 3.3 parse defensive unit tests | 21/21 (19 malformed all rejected + 2 legal unpackings) | malformed → nil+err | ✅ |
| 13 | 4.1 group key shape | `kong:rl:{p3-shape:g=3acf5710:r1:consumer=anon}` / `…r2:…:path=/echo`, same tag, reused across nodes | group fingerprint + r<i> segment + same slot | ✅ |
| 14 | 4.2 E2E one empty, one non-empty | 429, body `{"rule":"rules[1]:consumer","retry_after":6,…}`, Retry-After=6=ceil(5.04), Reset=now+6, R1/R2=0/5 unchanged, and the multi_reject decision log | the spec's core scenario | ✅ |
| 15 | 4.2 admission bottleneck headers (R1=5, R2=1.5 frozen) | 200, Remaining=0 (floor of 0.5), Reset−now=6, Limit=5 (bottleneck r2) | bottleneck basis | ✅ |
| 16 | 4.2 the 429 rule pointer (R1=0.2 frozen) | Retry-After=5=ceil(4.8), body rule=rules[1] | max(wait) | ✅ |
| 17 | 4.2 Retry-After cap | 3600 (= max window, not larger) | cap | ✅ |
| 18 | 4.3 backstop unit tests | 8/8 (batch>1/9 rules/header without a name all rejected; 8 rules/batch=1/legal pass; build_key injection → nil+kerr) | double guard | ✅ |
| 19 | 5.2 rules.sh full run | PASS=14 FAIL=0 (all green in one run) | all scenarios | ✅ |
| 20 | 6.1 dims.sh regression | PASS=8 FAIL=0 | consistent with the Phase 2 anchors | ✅ |
| 21 | 6.1 quota.sh batch=1 | allowed=100 / limited=350 / other=0, per-node 150 assertion | exactly 100 | ✅ |
| 22 | 6.1 dual failure paths | default 503; fault tolerance 200+degraded | consistent with Phase 1 | ✅ |

## 8. Log Analysis

- The multi-rule rejection decision log: `multi_reject keys=… reject=rules[1]:consumer wait=5.04…` (notice level), searchable and distinguishable from the admission log `multi_grant keys=… remaining=… bottleneck=r2`; the handler's 429 log contains the `reject=` segment.
- During group 4, `redis grant_multi failed: malformed multi eval response` appeared once (an eval argument misalignment bug, see §9-1); zero recurrences after the fix.

## 9. Issues Found (discovered during execution)

| # | Issue | Disposition |
|---|---|---|
| 1 | **eval argument misalignment bug**: in `r:eval(script, n, unpack(keys), unpack(argv))`, `unpack(keys)` sits mid-argument-list and Lua truncates it to 1 value → KEYS lost, ARGV shifted left (n becomes the first rate) → the script silently returns `{1}` with no writes. Located by injecting debug via resty (`#KEYS=2/n=0.1`) | fixed: explicitly flatten the args array and place `unpack(args)` at the end; after the fix, E2E all green |
| 2 | **userdata during init**: when the declarative configuration loads, `entity.config.rules` is a userdata proxy, and `#rules` inside fn crashes Kong at startup | fixed: a `type(rules) ~= "table"` defense (only at validation time is it a pure table) |
| 3 | When `build_group_keys` fails, the error message is discarded (`return nil, nil`) | fixed: the second return value is expanded correctly |
| 4 | Test scenario design error: preset R2=0.8 (<1) while expecting admission—measured 429 (wait=2.4→Retry-After=3), with headers and log fully self-consistent | not an implementation issue; after switching to the R2=1.5 scenario, the admission path matched |
| 5 | E2E cannot inject malformed Redis returns (same as Phase 2 §9-5) | the defensive validation is covered by resty pure-function unit tests (21 assertions); the standalone script's redis-cli bare-run provides real Redis-side evidence |
| 6 | The new environment lacked k6 | installed k6 v0.54.0 (~/.local/bin); the quota.sh regression is not blocked |

## 10. Risk Analysis

- **The group fingerprint's reset semantics**: changing any one rule = resetting the whole group's quota (a full-capacity new bucket), documented in README/design/rule.md; the escape hatch remains the namespace.
- **1 RTT per request**: the direct price of α (decided by the user); the multi-rule mode is not yet in the Phase 4 performance matrix and will be quantified as an independent measurement point then.
- **Cluster precondition**: same slot within the group is guaranteed by the group key (invisible on a single-instance Redis); if operations manually move multi-rule keys out of the group, multi-key EVAL will fail under Cluster—documented as a hard prerequisite.
- **The 429 `rule` field exposes the rule structure**: a human-readable identifier (`rules[2]:consumer+path`) rather than a bare internal index; the diagnostic value outweighs the information-leakage risk.
- **The userdata defense during init**: the validation-time semantics depend on the Admin API / `kong validate` path; declarative files with rules embedded in `kong.yml` do not trigger this check at init (depending on Kong's loading path); production is advised to deploy via the Admin API (the current deployment form does so).

## 11. Acceptance Verdict

**Passed (self-verified).** The spec's 5 ADDED requirements × scenarios comparison: multi-bucket all-or-nothing atomicity (§7-10/11/14), group keys and the group fingerprint (§7-13 + rules.sh scenario ③), configuration constraints (§7-1~8), response semantics (§7-15~17), and single-rule zero regression (§7-20~22). **No NOT RUN items** (§9-5 records the test-method difference: unit tests substitute for E2E injection).

Manual acceptance awaits user confirmation; suggested to spot-run `./bench/rules.sh` and compare against the Phase 2 manual's 429 Case.

## 12. Recommendations for the Next Phase

1. **Phase 4 (performance and inventory lifecycle)**: EVALSHA+NOSCRIPT (migrating the multi-key script together), the batch×RPS matrix (the multi-rule mode as an independent measurement point), quantifying stranding under non-uniform traffic, and the single-rule batch>1 graceful L2 return (preventing double return).
2. **Phase 5 (engineering hardening)**: Prometheus metrics (multi-rule dimensions suggested to be labeled by bottleneck rule), structured logging (replacing RL-DEBUG), L3 lease reconciliation, and long-run stability acceptance.
3. **The β enhancement (a separate change)**: multi-rule local multi-pool leases + deduct-verify-rollback, reusing α's group keys and script skeleton.
