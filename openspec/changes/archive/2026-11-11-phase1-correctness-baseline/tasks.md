# Tasks

> Spec basis: `specs/rate-limiting/spec.md`; implementation basis: `design.md` (D1–D8). Every task carries its own verification method; unexecuted/unexecutable verifications must be marked NOT RUN in `reports/phase-1-correctness.md`, and fabricating results is forbidden (rule.md 15.1-7).
>
> Execution conventions (aligned with the user on 2026-11-11): ① apply proceeds by task group; after each group, self-test and report briefly, with course corrections possible at any time; ② **one commit at the end of each task group** (group 1's 1.1 is the baseline commit), ensuring group-level rollback; ③ the spec coverage strategy is incremental per change—the rest of this capability's externally visible behavior (429/Retry-After/TTL/response headers, etc.) is added to the spec by later changes individually.

## 1. Rollback baseline and environment self-check

- [x] 1.1 Add `.gitignore` (`bench/out/` and other test artifacts), then `git add -A && git commit` for the baseline commit; verification: the baseline commit appears in `git log --oneline` and `git status` is clean (design D8)
- [x] 1.2 Environment self-check: `docker compose up -d`, the admin plane of the three nodes reachable at `/status`, `redis-cli ping` OK; verification: `docker compose ps` all running and `curl -s http://localhost:8031/status` returns 200; if the environment is unavailable, record it in the report and pause subsequent tasks

## 2. Redis Lua timestamp monotonicity (review finding P0-4, design D5)

- [x] 2.1 Modify the embedded script in `lib/redis.lua`: fold the refill and `ts = now` into the `if now > ts` branch, and `HSET` writes back the branch-internal ts rather than a bare `now`; verification: run `redis-cli --eval redis/token_bucket.lua` against a key preset with a "future ts"; no refill occurs and ts in the hash does not go backward
- [x] 2.2 Modify `redis/token_bucket.lua` in sync so the two scripts are verbatim identical; verification: diff of the two scripts is empty (the P2-3 dual-source issue is on record and not merged)
- [x] 2.3 Normal-path regression: after exhausting the bucket, wait briefly and request again; tokens refill by `elapsed × rate`, capped at burst; verification: measured timing curl data recorded in the report (corresponding to the spec's "refill amount matches the rate formula" scenario, prerequisite for data collection of rule.md test D)

## 3. Decision main-flow fix (design D3/D4/D6)

- [x] 3.1 In `algorithm.lua:check()`, move the nil check of `grant` forward to before any `granted.*` dereference; on failure go `kong.log.err` + `return nil, err`; verification: stop Redis and send one request (with the current default fault_tolerant=true); the log shows "failing open" with **no Lua traceback and no 500** (corresponding to the spec scenario "Redis failures MUST NOT produce HTTP 500")
- [x] 3.2 Implement the batch=1 short-circuit: `resolve_batch` runs up front; when `batch==1`, skip `store.take`/`store.fill`; verification: after a batch=1 load round, the `local_hit`/`local_fill` counts in the log are 0 (corresponding to the spec scenario "batch=1 produces no local inventory")
- [x] 3.3 Fix the IP fallthrough: change `kong.client.get_remote_ip` to the actually existing PDK `kong.client.get_ip()`; verification: a single node's `curl -i :8030/echo` returns a normal 200 with `X-RateLimit-*` headers (behavior unchanged, only eliminating the potential nil call)

## 4. Policy fingerprint into the key (review finding P0-1, design D1)

- [x] 4.1 Add a pure function `policy_fingerprint(conf)` in `algorithm.lua` (FNV-1a 32-bit → 8-char lowercase hex; inputs limit, window, parsed burst, limit_by order, header_name (only for the header dimension); no kong.* dependency), and `build_key` outputs `kong:rl:{rl:p=<hex>:dim=val:...}`; verification: call the function directly via `resty -e` (inside the Kong image or local lua5.1) and print the fingerprint
- [x] 4.2 Fingerprint property verification (scripted): changing limit/window/burst/limit_by order/header_name (with the header dimension) for any one item ⇒ the fingerprint changes; `burst=0` and `burst=limit` ⇒ the same value; changing only batch ⇒ the fingerprint is unchanged; verification: all assertions of the verification script pass and are recorded in the report
- [x] 4.3 Cross-configuration isolation measurement (the spec scenario "configuration change does not inherit the old quota"): first admit some requests with limit=1000, then switch to limit=100 and immediately send over-quota requests; global admissions ≤ 100; verification: measured via the quota flow after deploying the new configuration to the three nodes (the review-measured 116 > 100 no longer occurs)

## 5. Fail-closed default (review finding P0-2, design D2)

- [x] 5.1 Change the `fault_tolerant` default in `schema.lua` to false, and explicitly set `fault_tolerant: false` in `kong/kong.yml`; verification: after `docker compose restart kong*`, instances without explicit fault_tolerant return 503 when Redis is stopped (the spec scenario "default 503 after stopping Redis")
- [x] 5.2 Docs sync: README §7 acceptance list degraded row, §5 batch table note, `docs/design.md` §4.6/§7 failure modes, §9 trade-offs table, §12 key design (including the `p=` fingerprint and the cost "a policy change means a full-capacity new bucket"); verification: grep across the repo shows consistent `fault_tolerant`/key format wording with no residual fail-open default description
- [x] 5.3 Fault-tolerant mode retention verification: with explicit `fault_tolerant=true`, stopping Redis admits with `X-RateLimit-Status: degraded`, and normal behavior resumes after recovery; verification: manual configuration deployment + `docker compose stop/start redis` measurement (the spec scenario "fault-tolerant mode degrades and admits", rule.md test C's explicit fault-tolerance branch)

## 6. Load-test script convergence (review finding P0-6 + the P0-5 assertion, design D7)

- [x] 6.1 `bench/common.sh`'s `kong_config_json` gains a namespace parameter and explicitly writes `fault_tolerant:false`; `quota.sh`/`matrix.sh` generate an independent namespace per round; verification: two consecutive rounds' `redis-cli KEYS 'kong:rl:*'` differ in prefix/namespace segment, with no cross-round residue
- [x] 6.2 `bench/quota.sh` adds per-node assertions: the k6 summary's `requests_kong1/2/3` must each strictly equal PER_NODE, otherwise the script fails and exits; verification: a normal round passes; a deliberately non-divisible VUS combination makes the script fail (fail loudly)

## 7. IP dimension regression test (review finding P0-3 wrap-up, design D6)

- [x] 7.1 Add a spoofed-XFF scenario (e.g., `bench/xff.sh` or a quota.sh variant): same source IP, limit=1, batch=1, repeatedly requesting with different spoofed `X-Forwarded-For` values; verification: only the first request returns 200, all others return 429 (the spec scenario "spoofed XFF does not create a new bucket")

## 8. Phase 1 integration acceptance (rule.md tests A–D + report)

- [x] 8.1 Tests A+B (batch=1 strict baseline): 3 nodes × 150 concurrent, expecting allowed=100 / limited=350 / other=0, with the per-node assertion passing and 0 local inventory hits; verification: `./bench/quota.sh -l 100 -b 1 -p 150` all green (the spec scenario "batch=1 admits exactly limit globally")
- [x] 8.2 Test B variant (batch=20 no over-admission and the lower bound): expecting allowed ∈ [40, 100], observing and recording fluctuation over multiple rounds (without Phase 4's 10-repeat matrix); verification: `./bench/quota.sh -l 100 -b 20 -p 150` output falls in the interval (the spec scenarios "batch=20 admits no more than limit" and "batch=20 reaches the lower bound under uniform traffic")
- [x] 8.3 Test C (failure policy dual paths): default configuration → 503 without hitting upstream; explicit fault_tolerant=true → degraded admission; verification: both branches fully measured (same source as 5.1/5.3; a full-flow re-check here)
- [x] 8.4 Test D (token refill): use the data collected in 2.3 to verify `tokens += elapsed × rate`, the burst cap, and no double-billing under rollback; verification: the report includes the measured timing table
- [x] 8.5 Compile `reports/phase-1-correctness.md`: strictly following rule.md §13's twelve-section format (including environment notes: WSL mirrored, ports 8030/6380, pulling images via a proxy), unexecuted items marked NOT RUN; verification: the report covers all 8 test groups and corresponds to the raw logs/summary files; after manual acceptance passes, commit group 8's commit (the rollback anchors are jointly formed by the group-level commits of each task group)

## Workflow follow-up

- After manual acceptance passes, run `openspec archive phase1-correctness-baseline` (confirm first that reports/phase-1-correctness.md has been committed into `reports/`).
- The P1/P2 items left over from acceptance (unified reset/remaining basis, EVALSHA, Retry-After cap, dual-source script merge, P2-5 wrap-up beyond `.gitignore`, etc.) serve as input for the next change and are not expanded within this change.
