# Tasks

> Spec basis: `specs/rate-limiting/spec.md` (5 ADDED items); implementation basis: `design.md` (D1–D6). Continuing the execution conventions: proceed by group, self-test and report briefly per group, one commit per group, and unexecuted verifications marked NOT RUN in the report.

## 1. Baseline and up-front cross-check

- [x] 1.1 `git commit` for this change's baseline (an `--allow-empty` anchor if the tree is clean); verification: the baseline commit appears in `git log --oneline`
- [x] 1.2 Measure D2's limit_by distinguishing semantics: whether the entity_check comparison "rules non-empty + limit_by ≠ default" yields 400 as expected; verification: curl three cases (rules + default limit_by / rules + explicit limit_by / limit_by only); if imprecise, enable the degraded plan (ignore limit_by under the rules mode + init warn) and record it
- [x] 1.3 Environment self-check: three nodes healthy, FLUSHDB available; verification: `docker compose ps` all running

## 2. Configuration model (D2, schema.lua)

- [x] 2.1 Add the `rules` array field (elements: limit/window/burst/limit_by/header_name; len_max=8) + three entity_checks (mutual exclusion / batch∈{0,1} / cap); the runtime backstop validation in sync; verification: four measured cases—rules + limit_by co-present 400, rules + batch=20 400, 9 rules 400, a legal 2-rule configuration 201
- [x] 2.2 Old configuration regression verification: deployment of existing limit_by-only configurations is unaffected (201); verification: Phase 1/2's dims scenario configurations deploy successfully

## 3. Multi-key atomic script (D3/D4, redis.lua + the standalone script)

- [x] 3.1 Add `redis/multi_bucket.lua` (standalone bare-run script) and the embedded `GRANT_MULTI` script: KEYS = each rule's bucket key, ARGV = [n, each rule's rate/burst/ttl]; logic = per-bucket refill (TIME monotonic / burst cap) → check all (each bucket ≥1) → deduct all / deduct none → return {ok, each bucket's tokens/wait} or {ok=0, insufficient rules, each wait}; verification: diff of the two scripts is empty
- [x] 3.2 redis-cli bare-run of the core scenario: preset R1 tokens=0, R2 tokens=5 → after EVAL, R1/R2 remain 0/5 unchanged and the return is ok=0 + rule indices; preset both buckets sufficient → after EVAL each decreases by 1; verification: one-to-one correspondence with the spec scenarios
- [x] 3.3 `redis.lua` adds `grant_multi()` and the pure function `parse_multi_grant_response(n, res)` (structural/numeric/range defensive validation); verification: resty unit tests—malformed samples (wrong length/non-numeric/out-of-range/invalid ok) all rejected + legal samples pass

## 4. Decision and response semantics (D1/D5, algorithm.lua + handler.lua)

- [x] 4.1 `algorithm.lua` multi-rule branch: conf.rules non-empty → group key construction (group fingerprint + r<i> segment + each rule's dimension values) → grant_multi → assemble the decision (remaining=min, reset=the bottleneck bucket's now+wait, rule rejection info); verification: observe the group key shape via resty or curl (KEYS contain the group fingerprint and r1/r2 segments)
- [x] 4.2 `handler.lua` multi-rule responses: admission headers (Remaining=min / Reset=bottleneck), the 429 body containing the `rule` field, Retry-After=max(wait) capped at max(window), and the decision log including the rejected rule; verification: measure the 429 body and headers (preset one empty, one non-empty)
- [x] 4.3 Runtime backstop validation (under the rules mode, batch>1 or over 8 rules → 500 misconfigured, a double guard); verification: a resty unit test path injecting conf directly, bypassing the schema

## 5. Multi-dimensional verification script (D6, bench/rules.sh)

- [x] 5.1 Write `bench/rules.sh`: scenario ① all-or-nothing core (redis-cli presets one empty, one non-empty → 429 and both buckets' tokens unchanged); ② all sufficient, admit and deduct 1 each; ③ group fingerprint changes buckets (changing one rule → the group fingerprint segment changes); ④ response semantics (bottleneck headers / the 429 rule field / Retry-After cap); ⑤ the three bad-configuration 400s; an independent namespace per scenario; verification: the script's PASS/FAIL assertions complete
- [x] 5.2 Run `bench/rules.sh` all green; verification: all scenarios PASS (a FAIL means stop and investigate; getting green by fudging is forbidden)

## 6. Regression, docs, and report

- [x] 6.1 Single-rule regression: dims.sh all green + quota.sh batch=1 baseline (100/350/0) + a spot check of the dual failure paths; verification: consistent with the existing anchors
- [x] 6.2 Docs sync: README (the rules configuration example and response headers), docs/design.md (§2/§4 multi-rule atomicity and group keys), docs/architecture.md (the decision flow diagram's multi-rule branch), rule.md (the key structure §3 and the α decision record); verification: grep shows no omissions/conflicting statements
- [x] 6.3 Compile `reports/phase-3-multi-rule.md` (§13 format, either no NOT RUN or truthfully marked); verification: covering all spec scenarios and the measured design decisions; after manual acceptance passes, commit group 6's commit

## Workflow follow-up

- After manual acceptance passes, run `openspec archive phase3-multi-rule` (the spec is appended into the main spec).
- Deferred inputs: the β local multi-pool lease, the L2 graceful return, the L3 lease reconciliation, and the multi-rule mode's performance matrix measurement point → Phases 4/5.
