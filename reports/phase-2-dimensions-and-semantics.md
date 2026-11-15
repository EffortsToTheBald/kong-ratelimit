# Test Report — Phase 2 Multi-Dimensional Semantics and Observability Baseline

## 1. Test Purpose

Verify that all 11 ADDED requirements of `phase2-dimensions-and-semantics` have landed: multi-dimensional rate-limiting behavior (7 dimensions + combinations), response header semantics (Reset/Retry-After), observability (429 logs/degradation warning), defensive behavior (malformed Redis returns), and configuration pre-validation (header_name); and confirm zero regression of Phase 1's verified behavior.

## 2. Modified Files

| File | Type |
|---|---|
| `kong/plugins/rate-limit-advanced/schema.lua` | modified (entity_checks: conditional + contains) |
| `kong/plugins/rate-limit-advanced/handler.lua` | modified (init_worker degradation warning, 429 branch rewritten: cap/same-basis Reset/decision log, a new store dependency) |
| `kong/plugins/rate-limit-advanced/lib/redis.lua` | modified (wait formula unified, parse_grant_response defensive validation) |
| `kong/plugins/rate-limit-advanced/lib/algorithm.lua` | modified (reset computed per the basis, remaining basis comments) |
| `redis/token_bucket.lua` | modified (dual-source sync) |
| `bench/dims.sh` | new (multi-dimensional verification with 7 scenarios and 8 assertions) |
| `bench/common.sh` | modified (kong_config_json's 6th parameter limit_by) |
| `README.md` / `docs/design.md` / `rule.md` | modified (semantics and key format synced) |

## 3. Changes Made (corresponding to design D1–D9)

1. **D1 Reset semantics**: slow path `Reset = now + wait` (the script's wait unified as `max(0,(1−tokens)/rate)`); fast path `remaining>0 → now`, `=0 → now+⌈1/rate⌉`; the 429 is derived by the handler from the capped Retry-After.
2. **D2 Retry-After cap**: `min(max(1,ceil(wait)), floor(window))`.
3. **D3 Defensive validation**: the pure function `parse_grant_response(res, want)` (3-element array, granted an integer ∈[0,want], tokens/wait numeric, wait≥0); malformed → close + nil,err → the failure branch.
4. **D4 Pre-validation**: `entity_checks = {{ conditional = { if_field="config.limit_by", if_match={contains="header"}, then_field="config.header_name", then_match={required=true} } }}`; the main plan passed on the first attempt, no fallback needed.
5. **D5 Degradation warning**: `init_worker()` checks `store.backend()`; warns if not shared_dict.
6. **D6/D7 dims.sh**: 7 scenarios with independent namespace + FLUSHDB + assertions; the consumer scenario ships its own key-auth (anonymous pointing at the anonymous consumer) + alice/bob complete declarative configuration.
7. **D8/D9 Docs**: README's response header semantics table, design §7/§9, rule.md §3 key format (the `p=` fingerprint examples fully updated).
8. **Spec correction**: in the header missing-sentinel-bucket scenario, the first "headerless" request's expectation was corrected from 429 to 200 (an independent sentinel bucket; a planning typo, fixed before implementation).

## 4. Test Environment

Same as Phase 1: WSL2 (mirrored networking), 3× Kong 3.6.1 DB-less (2 workers per node, kong_rl 32m), a single Redis 7 instance (6380→6379), Docker Engine 29.1.5, k6 v2.3.0. Containers underwent multiple restarts during the change (required for schema/code to take effect).

## 5. Test Parameters

| Verification | Configuration |
|---|---|
| 429 same basis | limit=100 window=3600 batch=1 |
| cap boundary | limit=1 window=3600 |
| fast/slow path headers | limit=1000 window=60 batch=20 |
| entity_checks | limit_by=[header] (missing/with header_name), [ip] |
| dims 7 scenarios | their own limit and limit_by (see dims.sh), all batch=1 |
| consumer | key-auth anonymous=anon-visitor; alice/bob each holding a key; limit=1 |
| Regression | batch=1 baseline / dual failure paths / switching limit 1000→100 in the same namespace |

## 6. Test Commands

```bash
./bench/dims.sh                                    # multi-dimensional 7 scenarios
./bench/quota.sh -l 100 -b 1 -p 150                # Phase 1 regression
docker compose exec kong1 resty -e '...parse_grant_response samples...'   # defensive validation unit tests
docker compose exec kong1 resty -e '...policy_fingerprint order assertions...'
curl -X POST :8031/config -d '<bad/good config>'          # entity_check measurement
docker run --name p2degrade -e KONG_DATABASE=off ... kong:3.6   # degraded startup warning
```

## 7. Test Results

| # | Verification | Result | Expected | Status |
|---|---|---|---|---|
| 1 | dims scenario 1 [ip,path] | 200200200200429429 | two paths independent | ✅ |
| 2 | dims scenario 2 [method] | 200200429429 | GET/POST bucketed separately | ✅ |
| 3 | dims scenario 3 [header] | 200200429429200429 | dual tenants independent + missing sentinel independent | ✅ |
| 4 | dims scenario 4 [route] | key contains `route=a0233861-…`, 200/429 | route.id in the key | ✅ |
| 5 | dims scenario 5 [service] | key contains `service=adbd70b3-…`, 200/429 | service.id in the key | ✅ |
| 6 | dims scenario 6 [consumer] | 200429200429200429 (alice/bob/anon) | bucketed by authenticated identity + anon independent | ✅ |
| 7 | consumer without Lua exceptions | attempt to call = 0 | key-auth before rate limiting | ✅ |
| 8 | dims scenario 7 fingerprint order | 25c15179 ≠ 51a445f1 | order participates in the fingerprint | ✅ |
| 9 | 429 same basis | Retry-After=36 and Reset−now=36 | ±1s consistent | ✅ |
| 10 | Retry-After cap | limit=1/w=3600 → Retry-After=3600 | ≤ window | ✅ |
| 11 | fast/slow path Reset | both the current Unix second (has inventory ⇒ the next token is already available) | Unix seconds, this node's perspective | ✅ |
| 12 | entity_check rejection | bad configuration 400 (`header_name: required field missing`) | rejected at deployment | ✅ |
| 13 | entity_check admission | legal header configuration 201, existing ip configuration 201 | no false kills | ✅ |
| 14 | Defensive validation unit tests | all 10 malformed classes rejected + 2 legal passing | malformed → nil+err | ✅ |
| 15 | Degradation warning (negative) | normal startup has 0 entries | no false alarms | ✅ |
| 16 | Degradation warning (positive) | startup without shared dict → `[warn] ... degraded to worker_table` (one per worker, two total) | warned at startup | ✅ |
| 17 | Regression: batch=1 baseline | 100/350/0 + per-node 150 assertion | consistent with Phase 1 | ✅ |
| 18 | Regression: dual failure paths | default 503; explicit fault tolerance 200+degraded | consistent with Phase 1 | ✅ |
| 19 | Regression: fingerprint isolation | switching limit 1000→100 in the same ns → exactly 100×200; the dual fingerprints `8039753e`/`50780f62` match the anchors | zero inheritance | ✅ |

## 8. Log Analysis

- 429 decision log: `rate-limit-advanced: 429 key=<key> limit=100 batch=1` (notice level, observed in measurement), searchable and distinguishable from the failure path's error/warn logs.
- The consumer scenario (key-auth first) had no `attempt to call` exceptions throughout.
- The degradation warning appears only at startups missing the shared dict (2 entries per instance positive, 0 negative).
- The entity_check 400 error body contains readable field location (`config.header_name: required field missing`).

## 9. Issues Found (discovered during execution)

| # | Issue | Disposition |
|---|---|---|
| 1 | `kong_config_json` hardcoded `limit_by:["ip"]` with no limit_by parameter—dims scenario 1's first run counted everything by ip and FAILed | fixed: added the 6th parameter (default `["ip"]`, keeping compatibility with existing calls) |
| 2 | Spec scenario typo: the first "headerless" request in the header missing-sentinel-bucket scenario should be admitted (a brand-new bucket) rather than 429 | found before implementation; the delta was corrected; dims scenario 3 passes per the corrected expectation |
| 3 | Group 6's regression script `mk()` hardcoded limit=100; the first run of "regression 3" was actually two rounds of the same limit with different ns (an invalid verification) | recorded truthfully; re-run parameterized; the corrected results are in §7-19 |
| 4 | dims scenario 3's initial configuration (without header_name) was rejected with 400 | not a problem—exactly another proof of the pre-validation (a field omitted by the configuration generator is intercepted) |
| 5 | E2E cannot inject malformed Redis returns | the defensive validation is covered by resty pure-function unit tests (10 malformed + 2 legal); the grant→check→fail branch wiring is a direct code path, and the fail branch's behavior was corroborated by Phase 1's stop-Redis measurement |

## 10. Risk Analysis

- `Reset=now` may be misread by clients as "the window has reset"—the semantics are "the next token is already available"; README/design explicitly state the token bucket model and "this node's perspective".
- The fast path's `Reset=now+⌈1/rate⌉` is a conservative approximation (when Redis will grant again is unknowable locally).
- The defensive validation surface covers only the EVAL return structure (no business semantics); the misjudgment surface is tiny; `wait<0` is also treated as malformed (legal paths are always ≥0).
- The 429 notice log amplifies log volume under high rejection rates (same magnitude as RL-DEBUG); unified governance when Phase 5 does structured logging.

## 11. Acceptance Verdict

**Passed (self-verified).** The spec's 11 ADDED requirements × scenarios comparison: §7-1/3 (multi-dimensional combinations), §7-2 (method), §7-3 (header), §7-6/7 (consumer), §7-4/5 (route/service), §7-12/13 (pre-validation), §7-9/11 (Reset semantics), §7-10 (Retry-After cap), §7-8 (429 observability), §7-14 (defensive validation), §7-15/16 (degradation warning); Phase 1 regressions §7-17/18/19 all green. **No NOT RUN items** (§9-5 records the test-method difference: unit tests substitute for E2E injection).

Manual acceptance awaits user confirmation; after confirmation, commit group 6's commit (the group this report belongs to).

## 12. Recommendations for the Next Phase

1. **Phase 4 (performance and inventory lifecycle)**: EVALSHA+NOSCRIPT, the batch×RPS matrix (M0/1/5/20/auto × RPS), quantifying stranding under non-uniform traffic, node restart scenarios, inventory recovery design (with matrix data as input), and filling design.md §8's three ⟨TODO⟩ in `bench/results.md`.
2. **Phase 5 (engineering hardening)**: Prometheus metrics, structured logging (replacing RL-DEBUG), long-run stability acceptance in final-acceptance.md.
3. **rule.md leftovers**: special character escaping/concatenation ambiguity, per-rule IDs, path normalization (see rule.md §3.4's updated list).
