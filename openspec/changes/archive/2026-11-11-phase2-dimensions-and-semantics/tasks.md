# Tasks

> Spec basis: `specs/rate-limiting/spec.md` (11 ADDED items); implementation basis: `design.md` (D1–D9). Continuing the execution conventions: proceed by task group, self-test and report briefly per group, one commit per group, and unexecuted verifications marked NOT RUN in the report.

## 1. Baseline and up-front fact checking

- [x] 1.1 `git add -A && git commit` for this change's baseline commit; verification: the baseline commit appears in `git log --oneline`
- [x] 1.2 Measure the feasibility of D4's main plan: after deploying a schema modification with `entity_checks` (conditional+contains) to the Admin API, submit a configuration with `limit_by=[header]` and no header_name; confirm a 400 is returned and `contains` works on arrays; verification: measured 400 via curl; if it does not work, switch to design D4's `custom_entity_check` fallback and record it
- [x] 1.3 Environment self-check (continuing Phase 1's prelude): three nodes healthy, FLUSHDB available; verification: `docker compose ps` all running

## 2. Response header semantics (D1/D2/D8, redis.lua + handler.lua)

- [x] 2.1 `redis.lua`: unify the script's wait formula as `wait = max(0, (1 - tokens) / rate)` (0 when tokens≥1); sync `redis/token_bucket.lua`; verification: `diff` of the two scripts' bodies is empty; resty fed tokens=2.3/0.7 samples asserting wait=0/positive
- [x] 2.2 `handler.lua`: slow path `reset = now + wait`, fast path branching per remaining (>0 → now; =0 → now+⌈1/rate⌉), `retry_after = min(max(1, ceil(wait)), floor(window))`, and a notice log in the 429 branch (key/limit/batch); verification: with limit=100 batch=1, after manual exhaustion the 429 response satisfies `Reset − now ≈ Retry-After` (±1s); with limit=1/window=3600, a 429 yields `Retry-After ≤ 3600`
- [x] 2.3 `algorithm.lua`: the remaining basis comment (both paths are this node's perspective) and minor reset value-passing tweaks; verification: curl shows the fast/slow path response headers in the same format (both Unix seconds)

## 3. Validation and defense (D3/D4/D5)

- [x] 3.1 `schema.lua` adds `entity_checks` (conditional + contains, or the plan chosen in 1.2); verification: deploying `limit_by=[header]` without header_name → 400; deploying a legal header configuration → success; deployment of existing configurations without header is unaffected
- [x] 3.2 `redis.lua` extracts the pure function `parse_grant_response(res, want)` and wires it into grant() (malformed → close + nil,err); verification: resty unit tests fed 5 classes of malformed samples (non-table/length≠3/granted non-numeric/granted>want/tokens non-numeric) all return nil+err, and legal samples pass
- [x] 3.3 `handler.lua` adds `_M:init_worker()` (backend not shared_dict → log.warn); verification: start once with KONG_NGINX_HTTP_LUA_SHARED_DICT removed (docker compose env override); the startup log shows the degradation warning; after restoring the normal configuration the warning disappears
- [x] 3.4 Failure branch verification of malformed returns (combined with 3.2): confirm the code path malformed → nil,err → handler fail branch; verification: proven by logs and branch unit tests (E2E injection is infeasible; the test method is recorded truthfully in the report)

## 4. Multi-dimensional verification script (D6/D7, bench/dims.sh)

- [x] 4.1 Write `bench/dims.sh`: 7 scenarios ([ip,path] independent / [method] bucketed / [header] dual tenants + sentinel / [route] / [service] / [consumer] dual consumers + anon / fingerprint order assertion), each with an independent namespace + FLUSHDB and PASS/FAIL assertions; the consumer scenario ships its own key-auth + alice/bob declarative configuration (the /echo-auth route)
- [x] 4.2 Run `bench/dims.sh` all green; verification: all 7 scenarios PASS (an unexpected FAIL means stop and investigate; adjusting acceptance criteria to get green is forbidden)
- [x] 4.3 Consumer scenario priority re-check: confirm key-auth (1250) runs before this plugin (1002) and the log has no "attempt to call" exceptions; verification: dims.sh consumer scenario output + no errors in the kong log

## 5. Docs sync (D8/D9)

- [x] 5.1 `README.md`: the response header semantics section (Reset = the Unix second when the next token is available, Retry-After≤window, remaining = this node's perspective, the 429 log); verification: consistent with the measured response headers
- [x] 5.2 `docs/design.md`: §7 response header semantics updated, §9 trade-offs table gains "reset basis/defensive validation" rows; verification: grep shows no residual old semantics ("window reset/now+window")
- [x] 5.3 `rule.md` §3.2/§3.3/§3.4: key format examples and explanations add the `p=` fingerprint (inputs, "a policy change means a new bucket", the namespace escape hatch); verification: grep confirms the old examples `kong:rl:{rl:ip=` are all updated
- [x] 5.4 `docs/review-phase-0.md` unchanged (historical record); verification: confirmed no accidental edits

## 6. Integration acceptance and report

- [x] 6.1 Regression: re-run Phase 1's key cases (batch=1 baseline 100/350/0, the dual failure paths, fingerprint isolation); verification: identical to Phase 1's results (the anchor table in `test/first-commit.md`)
- [x] 6.2 Full verification of the new semantics: dims.sh + reset/Retry-After/429 log/400 deployment/degradation warning archived item by item; verification: covering the scenarios of all 11 ADDED requirements in the spec
- [x] 6.3 Compile `reports/phase-2-dimensions-and-semantics.md` (rule.md §13 twelve-section format; unexecuted items marked NOT RUN); verification: the report corresponds to raw outputs/summaries; after manual acceptance passes, commit group 6's commit

## Workflow follow-up

- After manual acceptance passes, run `openspec archive phase2-dimensions-and-semantics` (the spec merges into the main spec as ADDED appends).
- Deferred inputs: EVALSHA/performance matrix/inventory lifecycle/non-uniform traffic → the Phase 4 change; Prometheus/structured logging → the Phase 5 change.
